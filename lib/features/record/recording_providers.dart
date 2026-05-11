import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../core/audio_session_bridge.dart';
import '../../core/background_task_bridge.dart';
import '../../core/db/job_state.dart';
import '../../core/db/providers.dart';
import '../../core/db/repositories/voice_log_repository.dart';
import '../../core/intent_bridge.dart';
import '../../core/live_activity_bridge.dart';
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
class RecordingController extends StateNotifier<RecordingState>
    with WidgetsBindingObserver {
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
       super(const RecordingIdle()) {
    WidgetsBinding.instance.addObserver(this);
  }

  final AudioRecorder _recorder;
  final VoiceLogRepository _repository;
  final Future<SpeechRecognizer> Function() _recognizerFactory;
  final JobQueue _jobQueue;
  final String _docsPath;
  final PipelineDebugSink _debug;
  final _log = Logger('recording_controller');

  Timer? _elapsedTimer;
  StreamSubscription<Uint8List>? _pcmSub;
  DateTime? _startedAt;
  String? _activeLogId;
  int _lastActivityUpdateSec = -1;
  bool _liveActivityStarted = false;
  bool _liveActivityStartInFlight = false;
  static const _defaultWaveformLevels = <double>[
    0.24,
    0.48,
    0.32,
    0.68,
    0.42,
    0.82,
    0.36,
    0.62,
    0.30,
    0.54,
    0.28,
    0.44,
  ];
  List<double> _waveformLevels = [..._defaultWaveformLevels];

  /// Begin a new recording session. No-op if already recording.
  Future<void> start() async {
    if (state is! RecordingIdle && state is! RecordingFailed) return;

    await AudioSessionBridge.ensureConfigured();

    final audioDir = Directory(p.join(_docsPath, 'audio'));
    if (!audioDir.existsSync()) audioDir.createSync(recursive: true);
    final id = 'log_${DateTime.now().microsecondsSinceEpoch}';
    final path = p.join(audioDir.path, '$id.wav');
    _activeLogId = id;
    _liveActivityStarted = false;
    _liveActivityStartInFlight = false;

    final started = await _recorder.start(destinationPath: path);
    switch (started) {
      case Ok():
        break;
      case Err(:final error):
        state = RecordingFailed(error.message);
        _activeLogId = null;
        _liveActivityStarted = false;
        _liveActivityStartInFlight = false;
        return;
    }

    _debug.record(
      logId: id,
      stage: PipelineDebugStage.recording,
      event: 'started',
      message: 'Recording started',
    );
    _startedAt = DateTime.now();
    _lastActivityUpdateSec = 0;
    _startWaveformMonitor();
    state = const RecordingActive(0);
    unawaited(_tryStartLiveActivity());
    unawaited(IntentBridge.reportRecordingState(isRecording: true));
    _elapsedTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      final startedAt = _startedAt;
      if (startedAt == null) return;
      final elapsed = DateTime.now().difference(startedAt).inMilliseconds;
      state = RecordingActive(elapsed);

      final elapsedSec = elapsed ~/ 1000;
      if (elapsedSec > _lastActivityUpdateSec) {
        _lastActivityUpdateSec = elapsedSec;
        if (_liveActivityStarted) {
          unawaited(
            LiveActivityBridge.updateActivity(
              elapsedSeconds: elapsedSec,
              startedAt: startedAt,
              waveformLevels: _waveformLevels,
            ),
          );
        }
      }
    });
  }

  /// Stop, transcribe the completed file, persist the raw transcript,
  /// enqueue background refine, and return to idle.
  ///
  /// Requests background execution time from iOS so the pipeline completes
  /// even if the app enters the background (e.g. stop from Live Activity).
  Future<void> stop() async {
    if (state is! RecordingActive) return;
    _elapsedTimer?.cancel();
    _elapsedTimer = null;
    state = const RecordingTranscribing();
    await _stopWaveformMonitor();
    final bgTaskId = await BackgroundTaskBridge.begin();
    if (_liveActivityStarted) {
      unawaited(
        LiveActivityBridge.updateActivity(
          elapsedSeconds: _lastActivityUpdateSec,
          startedAt: _startedAt,
          isTranscribing: true,
          waveformLevels: _waveformLevels,
        ),
      );
    }

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
        _liveActivityStarted = false;
        _liveActivityStartInFlight = false;
        unawaited(LiveActivityBridge.endActivity());
        unawaited(IntentBridge.reportRecordingState(isRecording: false));
        unawaited(BackgroundTaskBridge.end(bgTaskId));
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
        _liveActivityStarted = false;
        _liveActivityStartInFlight = false;
        unawaited(LiveActivityBridge.endActivity());
        unawaited(IntentBridge.reportRecordingState(isRecording: false));
        unawaited(BackgroundTaskBridge.end(bgTaskId));
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
    unawaited(BackgroundTaskBridge.scheduleProcessingTask());

    _debug.record(
      logId: insertedLogId,
      stage: PipelineDebugStage.recording,
      event: 'returned_to_home',
      elapsedMs: totalWatch.elapsedMilliseconds,
      message: 'Stop-to-home path completed',
    );
    _startedAt = null;
    _activeLogId = null;
    _lastActivityUpdateSec = -1;
    _liveActivityStarted = false;
    _liveActivityStartInFlight = false;
    state = const RecordingIdle();
    unawaited(LiveActivityBridge.endActivity());
    unawaited(IntentBridge.reportRecordingState(isRecording: false));
    unawaited(BackgroundTaskBridge.end(bgTaskId));
  }

  void _startWaveformMonitor() {
    _waveformLevels = [..._defaultWaveformLevels];
    unawaited(_pcmSub?.cancel());
    _pcmSub = _recorder.pcm16Stream.listen(
      (chunk) {
        final level = _normalizedPcmLevel(chunk);
        _waveformLevels = [..._waveformLevels.skip(1), level];
      },
      onError: (Object e, StackTrace s) =>
          _log.w('PCM stream error', error: e, stack: s),
    );
  }

  Future<void> _stopWaveformMonitor() async {
    await _pcmSub?.cancel();
    _pcmSub = null;
  }

  double _normalizedPcmLevel(Uint8List chunk) {
    if (chunk.lengthInBytes < 2) return 0.08;
    final data = ByteData.sublistView(chunk);
    final sampleCount = chunk.lengthInBytes ~/ 2;
    var sumSquares = 0.0;
    for (var i = 0; i < sampleCount; i++) {
      final sample = data.getInt16(i * 2, Endian.little) / 32768.0;
      sumSquares += sample * sample;
    }
    final rms = math.sqrt(sumSquares / sampleCount);
    return (rms * 5).clamp(0.08, 1.0).toDouble();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && this.state is RecordingActive) {
      unawaited(_tryStartLiveActivity());
    }
  }

  Future<void> _tryStartLiveActivity() async {
    if (_liveActivityStarted || _liveActivityStartInFlight) return;
    final startedAt = _startedAt;
    if (startedAt == null || state is! RecordingActive) return;

    _liveActivityStartInFlight = true;
    try {
      final started = await LiveActivityBridge.startActivity(
        startedAt: startedAt,
        waveformLevels: _waveformLevels,
      );
      if (started && _startedAt == startedAt && state is RecordingActive) {
        _liveActivityStarted = true;
      } else if (started) {
        unawaited(LiveActivityBridge.endActivity());
      }
    } finally {
      _liveActivityStartInFlight = false;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _elapsedTimer?.cancel();
    unawaited(_stopWaveformMonitor());
    super.dispose();
  }
}

/// Long-lived controller that survives screen transitions, background/foreground
/// cycling, and external triggers (Live Activity, Siri intents).
final recordingControllerProvider =
    StateNotifierProvider<RecordingController, RecordingState>((ref) {
      ref.keepAlive();
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
