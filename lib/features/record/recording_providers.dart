import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../core/db/job_state.dart';
import '../../core/db/providers.dart';
import '../../core/db/repositories/voice_log_repository.dart';
import '../../core/logger.dart';
import '../../core/model_bootstrap.dart';
import '../../core/pipeline_debug.dart';
import '../../core/pipeline_debug_provider.dart';
import '../../core/result.dart';
import '../../core/worker/job_queue.dart';
import '../../core/worker/providers.dart';
import 'audio_recorder.dart';
import 'parakeet_runner.dart';
import 'speech_recognizer.dart';

/// Platform audio recorder. Disposed on teardown.
final audioRecorderProvider = Provider<AudioRecorder>((ref) {
  final r = RecordPackageAudioRecorder();
  ref.onDispose(r.dispose);
  return r;
});

/// Copies model assets out of the APK on first access.
final modelBootstrapProvider = Provider<ModelBootstrap>(
  (ref) => ModelBootstrap(),
);

/// Factory for one-shot completed-file Parakeet transcription.
///
/// Realtime captions are intentionally disabled because the streaming model's
/// partial hypotheses are lower quality than completed-recording transcription.
/// The returned recognizer must be disposed after each transcription so the
/// large Parakeet native heap is released before Gemma refinement starts.
final speechRecognizerFactoryProvider =
    Provider<Future<SpeechRecognizer> Function()>((ref) {
      final bootstrap = ref.watch(modelBootstrapProvider);
      return () async {
        final paths = await bootstrap.ensureParakeet();
        final runner = ParakeetRunner(paths: paths);
        final loaded = await runner.load();
        switch (loaded) {
          case Ok():
            return runner;
          case Err(:final error):
            await runner.dispose();
            throw StateError('Parakeet ASR load failed: ${error.message}');
        }
      };
    });

/// UI state for the record screen.
sealed class RecordingState {
  const RecordingState();
}

/// Idle — no recording in progress.
final class RecordingIdle extends RecordingState {
  const RecordingIdle();
}

/// Recording is active — [elapsedMs] ticks up as recording continues.
final class RecordingActive extends RecordingState {
  const RecordingActive(this.elapsedMs);
  final int elapsedMs;
}

/// Recording stopped; audio is being finalized, transcribed, and saved.
final class RecordingTranscribing extends RecordingState {
  const RecordingTranscribing();
}

/// Failure surfaced to the UI so the user can retry.
final class RecordingFailed extends RecordingState {
  const RecordingFailed(this.message);
  final String message;
}

/// State notifier that orchestrates record → transcribe → persist.
///
/// Chosen over a single `Future<void>` method so the UI can observe the
/// intermediate `transcribing` state without extra plumbing.
class RecordingController extends StateNotifier<RecordingState> {
  RecordingController({
    required AudioRecorder recorder,
    required VoiceLogRepository repository,
    required Future<SpeechRecognizer> Function() recognizerFactory,
    required JobQueue jobQueue,
    required String docsPath,
    PipelineDebugSink debugSink = const NoopPipelineDebugSink(),
  }) : _recorder = recorder,
       _repository = repository,
       _recognizerFactory = recognizerFactory,
       _jobQueue = jobQueue,
       _docsPath = docsPath,
       _debug = debugSink,
       super(const RecordingIdle());

  final AudioRecorder _recorder;
  final VoiceLogRepository _repository;
  final Future<SpeechRecognizer> Function() _recognizerFactory;
  final JobQueue _jobQueue;
  final String _docsPath;
  final PipelineDebugSink _debug;
  final _log = Logger('recording_controller');

  Timer? _elapsedTimer;
  DateTime? _startedAt;
  String? _activeLogId;

  /// Begin a new recording session. No-op if already recording.
  Future<void> start() async {
    if (state is! RecordingIdle && state is! RecordingFailed) return;
    final audioDir = Directory(p.join(_docsPath, 'audio'));
    if (!audioDir.existsSync()) audioDir.createSync(recursive: true);
    final id = 'log_${DateTime.now().microsecondsSinceEpoch}';
    final path = p.join(audioDir.path, '$id.wav');
    _activeLogId = id;

    final started = await _recorder.start(destinationPath: path);
    switch (started) {
      case Ok():
        break;
      case Err(:final error):
        state = RecordingFailed(error.message);
        _activeLogId = null;
        return;
    }

    _debug.record(
      logId: id,
      stage: PipelineDebugStage.recording,
      event: 'started',
      message: 'Recording started',
    );
    _startedAt = DateTime.now();
    state = const RecordingActive(0);
    _elapsedTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      final startedAt = _startedAt;
      if (startedAt == null) return;
      final elapsed = DateTime.now().difference(startedAt).inMilliseconds;
      state = RecordingActive(elapsed);
    });
  }

  /// Stop, transcribe the completed file, persist the raw transcript,
  /// enqueue background refine, and return to idle.
  Future<void> stop() async {
    if (state is! RecordingActive) return;
    _elapsedTimer?.cancel();
    _elapsedTimer = null;
    state = const RecordingTranscribing();

    final logId = _activeLogId;
    final totalWatch = Stopwatch()..start();
    final stopWatch = Stopwatch()..start();
    final clip = await _recorder.stop();
    final RecordedClip recorded;
    switch (clip) {
      case Ok(:final value):
        recorded = value;
        _debug.record(
          logId: logId,
          stage: PipelineDebugStage.recording,
          event: 'captured',
          elapsedMs: stopWatch.elapsedMilliseconds,
          message: 'Audio captured (${value.durationMs}ms)',
        );
      case Err(:final error):
        state = RecordingFailed(error.message);
        _debug.record(
          logId: logId,
          stage: PipelineDebugStage.recording,
          event: 'failed',
          elapsedMs: stopWatch.elapsedMilliseconds,
          message: error.message,
        );
        _startedAt = null;
        _activeLogId = null;
        return;
    }

    state = const RecordingTranscribing();

    var rawTranscript = '';
    SpeechRecognizer? recognizer;
    try {
      final loadWatch = Stopwatch()..start();
      recognizer = await _recognizerFactory();
      _debug.record(
        logId: logId,
        stage: PipelineDebugStage.transcription,
        event: 'loaded',
        elapsedMs: loadWatch.elapsedMilliseconds,
        message: 'ASR recognizer ready',
      );

      final transcribeWatch = Stopwatch()..start();
      final txt = await recognizer.transcribeFile(recorded.audioPath);
      switch (txt) {
        case Ok(:final value):
          rawTranscript = value;
          _debug.record(
            logId: logId,
            stage: PipelineDebugStage.transcription,
            event: 'succeeded',
            elapsedMs: transcribeWatch.elapsedMilliseconds,
            message: 'Transcribed ${value.length} characters',
          );
        case Err(:final error):
          _log.w('Transcription failed: ${error.message}');
          _debug.record(
            logId: logId,
            stage: PipelineDebugStage.transcription,
            event: 'failed',
            elapsedMs: transcribeWatch.elapsedMilliseconds,
            message: error.message,
          );
      }
    } on Object catch (e, s) {
      _log.w('Transcription error', error: e, stack: s);
      _debug.record(
        logId: logId,
        stage: PipelineDebugStage.transcription,
        event: 'failed',
        message: 'Transcription error: $e',
      );
    } finally {
      if (recognizer != null) {
        final disposeWatch = Stopwatch()..start();
        await recognizer.dispose();
        _debug.record(
          logId: logId,
          stage: PipelineDebugStage.transcription,
          event: 'disposed',
          elapsedMs: disposeWatch.elapsedMilliseconds,
          message: 'ASR recognizer disposed',
        );
      }
    }

    final relPath = p.relative(recorded.audioPath, from: _docsPath);

    final persistWatch = Stopwatch()..start();
    final inserted = await _repository.insertRecorded(
      id: p.basenameWithoutExtension(recorded.audioPath),
      createdAt: _startedAt ?? DateTime.now(),
      durationMs: recorded.durationMs,
      audioPath: relPath,
      rawTranscript: rawTranscript,
    );
    final String insertedLogId;
    switch (inserted) {
      case Ok(:final value):
        insertedLogId = value.id;
        _debug.record(
          logId: insertedLogId,
          stage: PipelineDebugStage.persistence,
          event: 'succeeded',
          elapsedMs: persistWatch.elapsedMilliseconds,
          message: 'Saved voice log and FTS row',
        );
      case Err(:final error):
        state = RecordingFailed(error.message);
        _debug.record(
          logId: logId,
          stage: PipelineDebugStage.persistence,
          event: 'failed',
          elapsedMs: persistWatch.elapsedMilliseconds,
          message: error.message,
        );
        _startedAt = null;
        _activeLogId = null;
        return;
    }

    final enqueueWatch = Stopwatch()..start();
    final jobId = await _jobQueue.enqueue(
      logId: insertedLogId,
      type: JobType.refine,
    );
    _debug.record(
      logId: insertedLogId,
      jobId: jobId,
      stage: PipelineDebugStage.queue,
      event: 'enqueued',
      elapsedMs: enqueueWatch.elapsedMilliseconds,
      message: 'Queued refine job',
    );

    _debug.record(
      logId: insertedLogId,
      stage: PipelineDebugStage.recording,
      event: 'returned_to_home',
      elapsedMs: totalWatch.elapsedMilliseconds,
      message: 'Stop-to-home path completed',
    );
    _startedAt = null;
    _activeLogId = null;
    state = const RecordingIdle();
  }

  @override
  void dispose() {
    _elapsedTimer?.cancel();
    super.dispose();
  }
}

/// Provides the controller, rebuilt when any upstream dependency changes.
final recordingControllerProvider =
    StateNotifierProvider.autoDispose<RecordingController, RecordingState>((
      ref,
    ) {
      final recorder = ref.watch(audioRecorderProvider);
      final repo = ref.watch(voiceLogRepositoryProvider);
      final recognizerFactory = ref.watch(speechRecognizerFactoryProvider);
      final queue = ref.watch(jobQueueProvider);
      final docsPath = ref.watch(appDocumentsPathProvider);
      final debugSink = ref.watch(pipelineDebugSinkProvider);
      return RecordingController(
        recorder: recorder,
        repository: repo,
        recognizerFactory: recognizerFactory,
        jobQueue: queue,
        docsPath: docsPath,
        debugSink: debugSink,
      );
    });
