import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../asr/models/transcript.dart';
import '../../asr/parakeet_runner.dart';
import '../../capture/capture_service.dart';
import '../../capture/models/speech_segment.dart';
import '../../capture/push_to_talk_processor.dart';
import '../../embed/e5_embedder.dart';
import '../../llm/cleanup_pipeline.dart';
import '../../llm/gemma_runner.dart';
import '../../llm/models/cleaned_transcript.dart';
import '../../store/models/voice_log_record.dart';
import '../../store/voice_log_repository.dart';
import 'debug_providers.dart';

/// Coarse-grained phase the debug flow is currently in. The screen uses
/// this to decide which sections render and which show spinners.
enum DebugRunPhase {
  /// Fresh state — user hasn't hit record yet, or we've just reset.
  idle,

  /// Mic open, segments streaming. **No ASR is loaded during this phase**
  /// — segments are buffered and transcribed after Stop.
  recording,

  /// [CaptureService.stop] has returned; we're running the sequential
  /// load→use→dispose pipeline (Parakeet → Gemma → E5 → ingest).
  postProcessing,

  /// Everything ran to completion.
  done,

  /// Something fatal happened. See [DebugRunState.errorMessage].
  error,
}

/// Finer-grained indicator of *which* heavy model is loaded right now.
/// Helpful when the user's on a memory-constrained device and wants to
/// know which stage is gating.
enum DebugSubphase {
  idle,
  finalizingRecording,
  loadingAsr,
  transcribing,
  disposingAsr,
  loadingLlm,
  cleaning,
  disposingLlm,
  loadingEmbedder,
  embedding,
  ingesting,
  disposingEmbedder;

  String get label => switch (this) {
        DebugSubphase.idle => 'idle',
        DebugSubphase.finalizingRecording => 'finalizing recording',
        DebugSubphase.loadingAsr => 'loading ASR model',
        DebugSubphase.transcribing => 'transcribing segments',
        DebugSubphase.disposingAsr => 'unloading ASR',
        DebugSubphase.loadingLlm => 'loading LLM',
        DebugSubphase.cleaning => 'cleanup (Gemma)',
        DebugSubphase.disposingLlm => 'unloading LLM',
        DebugSubphase.loadingEmbedder => 'loading embedder',
        DebugSubphase.embedding => 'embedding chunks',
        DebugSubphase.ingesting => 'ingesting into store',
        DebugSubphase.disposingEmbedder => 'unloading embedder',
      };
}

/// One row in the "live segments" list. During recording the transcript
/// is null — transcription only runs after Stop, once Parakeet is
/// loaded. Filled in as the post-processing pass walks the queue.
class DebugSegment {
  const DebugSegment({
    required this.id,
    required this.startMs,
    required this.endMs,
    required this.pcmBytes,
    this.pcm,
    this.transcript,
    this.transcribeMs,
    this.errorMessage,
  });

  /// Monotonic emission counter — unique within this run.
  final int id;
  final int startMs;
  final int endMs;
  final int pcmBytes;

  /// Kept in memory from capture until the transcribe step runs, then
  /// cleared to let the bytes get GC'd. For a debug UI on ≤60s takes
  /// this sits at a few MB at worst.
  final Uint8List? pcm;

  final Transcript? transcript;
  final int? transcribeMs;
  final String? errorMessage;

  int get durationMs => endMs - startMs;

  DebugSegment copyWith({
    Uint8List? pcm,
    bool clearPcm = false,
    Transcript? transcript,
    int? transcribeMs,
    String? errorMessage,
  }) {
    return DebugSegment(
      id: id,
      startMs: startMs,
      endMs: endMs,
      pcmBytes: pcmBytes,
      pcm: clearPcm ? null : (pcm ?? this.pcm),
      transcript: transcript ?? this.transcript,
      transcribeMs: transcribeMs ?? this.transcribeMs,
      errorMessage: errorMessage ?? this.errorMessage,
    );
  }
}

/// One chunk plus its embedding preview. Filled in during the embed
/// stage; the repo's internal embed uses the same loaded instance so
/// peak RAM is just one E5 copy.
class DebugChunkPreview {
  const DebugChunkPreview({required this.chunk, this.embedding});

  final TopicChunk chunk;
  final Float32List? embedding;

  DebugChunkPreview withEmbedding(Float32List e) =>
      DebugChunkPreview(chunk: chunk, embedding: e);
}

/// Full state of the current record → store run.
class DebugRunState {
  const DebugRunState({
    required this.phase,
    required this.subphase,
    required this.captureState,
    required this.segments,
    required this.chunkPreviews,
    this.recording,
    this.cleaned,
    this.cleanupMs,
    this.embedMs,
    this.storedLogId,
    this.storedChunkCount,
    this.gemmaDownloadPercent,
    this.errorMessage,
  });

  final DebugRunPhase phase;
  final DebugSubphase subphase;
  final CaptureState captureState;
  final List<DebugSegment> segments;
  final RecordingHandle? recording;
  final CleanedTranscript? cleaned;
  final int? cleanupMs;
  final List<DebugChunkPreview> chunkPreviews;
  final int? embedMs;
  final VoiceLogId? storedLogId;
  final int? storedChunkCount;

  /// 0..100 while flutter_gemma is fetching the `.task` bundle over
  /// HTTPS on first launch. Null when no download is in flight.
  final int? gemmaDownloadPercent;

  final String? errorMessage;

  factory DebugRunState.initial() => const DebugRunState(
        phase: DebugRunPhase.idle,
        subphase: DebugSubphase.idle,
        captureState: CaptureState.idle,
        segments: <DebugSegment>[],
        chunkPreviews: <DebugChunkPreview>[],
      );

  DebugRunState copyWith({
    DebugRunPhase? phase,
    DebugSubphase? subphase,
    CaptureState? captureState,
    List<DebugSegment>? segments,
    RecordingHandle? recording,
    CleanedTranscript? cleaned,
    int? cleanupMs,
    List<DebugChunkPreview>? chunkPreviews,
    int? embedMs,
    VoiceLogId? storedLogId,
    int? storedChunkCount,
    int? gemmaDownloadPercent,
    bool clearGemmaDownloadPercent = false,
    String? errorMessage,
  }) {
    return DebugRunState(
      phase: phase ?? this.phase,
      subphase: subphase ?? this.subphase,
      captureState: captureState ?? this.captureState,
      segments: segments ?? this.segments,
      recording: recording ?? this.recording,
      cleaned: cleaned ?? this.cleaned,
      cleanupMs: cleanupMs ?? this.cleanupMs,
      chunkPreviews: chunkPreviews ?? this.chunkPreviews,
      embedMs: embedMs ?? this.embedMs,
      gemmaDownloadPercent: clearGemmaDownloadPercent
          ? null
          : (gemmaDownloadPercent ?? this.gemmaDownloadPercent),
      storedLogId: storedLogId ?? this.storedLogId,
      storedChunkCount: storedChunkCount ?? this.storedChunkCount,
      errorMessage: errorMessage ?? this.errorMessage,
    );
  }
}

final debugRunProvider =
    NotifierProvider<DebugRunNotifier, DebugRunState>(DebugRunNotifier.new);

class DebugRunNotifier extends Notifier<DebugRunState> {
  StreamSubscription<SpeechSegment>? _segSub;
  StreamSubscription<CaptureState>? _stateSub;
  CaptureService? _capture;
  int _segSeq = 0;

  @override
  DebugRunState build() {
    ref.onDispose(() async {
      await _segSub?.cancel();
      await _stateSub?.cancel();
      await _capture?.dispose();
    });
    return DebugRunState.initial();
  }

  /// Reset to a clean slate. Used by the "new recording" button.
  /// Best-effort disposes any capture handle hanging around from a
  /// prior start() that errored before stop() could run.
  void reset() {
    _segSeq = 0;
    state = DebugRunState.initial();
    unawaited(_disposeCapture());
  }

  // -------------------------------------------------------------------
  // Recording
  // -------------------------------------------------------------------

  /// Open the mic and start streaming. Segments are **buffered** here
  /// (including their raw PCM) — no ASR model is loaded during
  /// recording, so transcription runs post-Stop.
  ///
  /// The [CaptureService] is constructed here (not in a provider) so
  /// platform-channel errors from the `record` plugin show up as a
  /// normal `DebugRunState.errorMessage` instead of gating boot.
  Future<void> start() async {
    if (state.phase != DebugRunPhase.idle) return;

    await _tearDownStreams();
    try {
      _capture = MicCaptureService(
        pcmSource: RecordPcmSource(),
        // Push-to-talk: the whole take emits as one segment on flush.
        vadProcessor: PushToTalkVadProcessor(),
      );
    } on Object catch (e) {
      state = state.copyWith(
        phase: DebugRunPhase.error,
        errorMessage: 'Failed to open mic: $e',
      );
      return;
    }

    _stateSub = _capture!.state.listen((cs) {
      state = state.copyWith(captureState: cs);
    });
    _segSub = _capture!.segments.listen((seg) {
      final id = _segSeq++;
      state = state.copyWith(
        segments: [
          ...state.segments,
          DebugSegment(
            id: id,
            startMs: seg.startMs,
            endMs: seg.endMs,
            pcmBytes: seg.pcm16kMono.length,
            pcm: seg.pcm16kMono,
          ),
        ],
      );
    });

    state = state.copyWith(phase: DebugRunPhase.recording);
    final started = await _capture!.start();
    if (started.isErr) {
      await _disposeCapture();
      state = state.copyWith(
        phase: DebugRunPhase.error,
        errorMessage: started.errOrNull?.toString(),
      );
    }
  }

  // -------------------------------------------------------------------
  // Post-processing — sequential load → use → dispose
  //
  // Peak RAM model:
  //   - Recording       : buffered PCM only (~32 KB/s)
  //   - Transcribing    : Parakeet   (~1.5 GB runtime)
  //   - Cleaning        : Gemma 270M (~400–600 MB runtime)
  //   - Embedding+store : E5         (~0.5–0.8 GB runtime)
  // Only ONE heavy model is resident at a time.
  // -------------------------------------------------------------------

  Future<void> stop() async {
    if (state.phase != DebugRunPhase.recording) return;
    state = state.copyWith(
      phase: DebugRunPhase.postProcessing,
      subphase: DebugSubphase.finalizingRecording,
    );

    final capture = _capture;
    if (capture == null) {
      state = state.copyWith(
        phase: DebugRunPhase.error,
        subphase: DebugSubphase.idle,
        errorMessage: 'internal: capture was null at stop()',
      );
      return;
    }
    final handleResult = await capture.stop();
    // Release the mic immediately — we don't need it again until the
    // user starts a fresh recording, and keeping `record` alive through
    // the Parakeet/Gemma/E5 stages wastes platform resources.
    await _disposeCapture();
    if (handleResult.isErr) {
      await _tearDownStreams();
      state = state.copyWith(
        phase: DebugRunPhase.error,
        subphase: DebugSubphase.idle,
        errorMessage: handleResult.errOrNull?.toString(),
      );
      return;
    }
    final recording = handleResult.okOrNull!;
    state = state.copyWith(recording: recording);

    // Stage 1: Transcribe. Load Parakeet → transcribe all → dispose.
    final transcribed = await _runTranscribeStage();
    if (!transcribed) return;

    // Combine segment transcripts into a single master. CleanupPipeline
    // only reads `.text`, so empty word lists here are fine — cross-
    // segment word-timing stitching is a future exercise.
    final perSegment = state.segments
        .map((s) => s.transcript)
        .whereType<Transcript>()
        .toList(growable: false);
    final combinedText = perSegment
        .map((t) => t.text.trim())
        .where((t) => t.isNotEmpty)
        .join(' ');
    if (combinedText.isEmpty) {
      await _tearDownStreams();
      state = state.copyWith(
        phase: DebugRunPhase.error,
        subphase: DebugSubphase.idle,
        errorMessage:
            'No speech detected. Check mic permission + try a louder take.',
      );
      return;
    }
    final master = Transcript(
      text: combinedText,
      words: const <Word>[],
      detectedLanguage:
          perSegment.isNotEmpty ? perSegment.first.detectedLanguage : 'en',
    );

    // Stage 2: Cleanup. Load Gemma → clean → dispose.
    final cleaned = await _runCleanupStage(master);
    if (cleaned == null) return;

    // Stage 3 + 4: Embed + ingest with a single loaded E5 instance.
    final core = await ref.read(coreRuntimeProvider.future);
    await _runEmbedAndIngestStage(
      core: core,
      recording: recording,
      master: master,
      cleaned: cleaned,
    );
  }

  /// Load Parakeet, drive it through every buffered segment, dispose.
  /// Returns true on success, false if the stage failed (in which case
  /// state has already been moved into the error phase).
  Future<bool> _runTranscribeStage() async {
    final core = await ref.read(coreRuntimeProvider.future);

    state = state.copyWith(subphase: DebugSubphase.loadingAsr);
    final asr = ParakeetRunner(modelDir: core.paths.parakeetDir);
    final loaded = await asr.load();
    if (loaded.isErr) {
      await _tearDownStreams();
      state = state.copyWith(
        phase: DebugRunPhase.error,
        subphase: DebugSubphase.idle,
        errorMessage: 'Parakeet load: ${loaded.errOrNull}',
      );
      return false;
    }

    state = state.copyWith(subphase: DebugSubphase.transcribing);
    for (final seg in state.segments) {
      final pcm = seg.pcm;
      if (pcm == null || seg.transcript != null) continue;
      final sw = Stopwatch()..start();
      final result = await asr.transcribe(pcm);
      sw.stop();

      final segments = [...state.segments];
      final idx = segments.indexWhere((s) => s.id == seg.id);
      if (idx != -1) {
        segments[idx] = segments[idx].copyWith(
          transcript: result.okOrNull,
          transcribeMs: sw.elapsedMilliseconds,
          errorMessage: result.isErr ? result.errOrNull?.toString() : null,
          clearPcm: true,
        );
        state = state.copyWith(segments: segments);
      }
    }

    state = state.copyWith(subphase: DebugSubphase.disposingAsr);
    await asr.dispose();
    return true;
  }

  /// Load Gemma, run cleanup, dispose. Returns the cleaned transcript
  /// on success, null on failure.
  ///
  /// First invocation pays a one-time ~290 MB download cost; the
  /// percentage is surfaced on [DebugRunState.gemmaDownloadPercent] so
  /// the UI can render a progress bar instead of an opaque spinner.
  Future<CleanedTranscript?> _runCleanupStage(Transcript master) async {
    state = state.copyWith(subphase: DebugSubphase.loadingLlm);
    final llm = GemmaRunner(
      onInstallProgress: (percent) {
        state = state.copyWith(gemmaDownloadPercent: percent);
      },
    );
    final loaded = await llm.load();
    // Clear the percent so the next render shows just the loading
    // spinner, not a stale 100% bar.
    state = state.copyWith(clearGemmaDownloadPercent: true);
    if (loaded.isErr) {
      await _tearDownStreams();
      state = state.copyWith(
        phase: DebugRunPhase.error,
        subphase: DebugSubphase.idle,
        errorMessage: 'Gemma load: ${loaded.errOrNull}',
      );
      return null;
    }

    state = state.copyWith(subphase: DebugSubphase.cleaning);
    final cleanup = CleanupPipeline(runner: llm);
    final cleanupSw = Stopwatch()..start();
    final cleanedResult = await cleanup.clean(master);
    cleanupSw.stop();

    state = state.copyWith(subphase: DebugSubphase.disposingLlm);
    await llm.dispose();

    if (cleanedResult.isErr) {
      await _tearDownStreams();
      state = state.copyWith(
        phase: DebugRunPhase.error,
        subphase: DebugSubphase.idle,
        errorMessage: 'Cleanup: ${cleanedResult.errOrNull}',
      );
      return null;
    }
    final cleaned = cleanedResult.okOrNull!;
    state = state.copyWith(
      cleaned: cleaned,
      cleanupMs: cleanupSw.elapsedMilliseconds,
      chunkPreviews: cleaned.chunks
          .map((c) => DebugChunkPreview(chunk: c))
          .toList(growable: false),
    );
    return cleaned;
  }

  /// Load E5, embed for UI preview, hand it to the repo for ingest
  /// (which re-embeds internally — wasted compute but the *loaded*
  /// footprint is still one embedder), dispose.
  Future<void> _runEmbedAndIngestStage({
    required CoreRuntime core,
    required RecordingHandle recording,
    required Transcript master,
    required CleanedTranscript cleaned,
  }) async {
    if (cleaned.chunks.isEmpty) {
      // Edge case: nothing to embed, nothing to store. Skip straight to done.
      await _tearDownStreams();
      state = state.copyWith(phase: DebugRunPhase.done);
      return;
    }

    state = state.copyWith(subphase: DebugSubphase.loadingEmbedder);
    final embedder = E5Embedder(
      weightsPath: core.paths.e5Weights,
      configPath: core.paths.e5Config,
      tokenizerPath: core.paths.e5Tokenizer,
    );
    final loaded = await embedder.load();
    if (loaded.isErr) {
      await _tearDownStreams();
      state = state.copyWith(
        phase: DebugRunPhase.error,
        subphase: DebugSubphase.idle,
        errorMessage: 'E5 load: ${loaded.errOrNull}',
      );
      return;
    }

    state = state.copyWith(subphase: DebugSubphase.embedding);
    final embedSw = Stopwatch()..start();
    final embedResult = await embedder.embedPassages(
      cleaned.chunks.map((c) => c.text).toList(),
    );
    embedSw.stop();
    if (embedResult.isOk) {
      final vecs = embedResult.okOrNull!;
      final previews = <DebugChunkPreview>[
        for (var i = 0; i < cleaned.chunks.length; i++)
          DebugChunkPreview(
            chunk: cleaned.chunks[i],
            embedding: i < vecs.length ? vecs[i] : null,
          ),
      ];
      state = state.copyWith(
        chunkPreviews: previews,
        embedMs: embedSw.elapsedMilliseconds,
      );
    }

    state = state.copyWith(subphase: DebugSubphase.ingesting);
    final repo = VoiceLogRepository(
      core.db,
      embedder: embedder,
      vectorIndex: core.vectorIndex,
    );
    final ingestResult = await repo.ingest(
      recording: recording,
      transcript: master,
      cleaned: cleaned,
    );

    state = state.copyWith(subphase: DebugSubphase.disposingEmbedder);
    await embedder.dispose();

    if (ingestResult.isErr) {
      await _tearDownStreams();
      state = state.copyWith(
        phase: DebugRunPhase.error,
        subphase: DebugSubphase.idle,
        errorMessage: 'Ingest: ${ingestResult.errOrNull}',
      );
      return;
    }

    await _tearDownStreams();
    state = state.copyWith(
      phase: DebugRunPhase.done,
      subphase: DebugSubphase.idle,
      storedLogId: ingestResult.okOrNull,
      storedChunkCount: cleaned.chunks.length,
    );
  }

  Future<void> _tearDownStreams() async {
    await _segSub?.cancel();
    await _stateSub?.cancel();
    _segSub = null;
    _stateSub = null;
  }

  Future<void> _disposeCapture() async {
    await _tearDownStreams();
    final capture = _capture;
    _capture = null;
    await capture?.dispose();
  }
}
