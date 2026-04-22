import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/db/providers.dart';
import '../../core/db/repositories/voice_log_repository.dart';
import '../../core/logger.dart';
import '../../core/model_bootstrap.dart';
import '../../core/result.dart';
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

/// Lazy Parakeet recognizer — first `read` copies model files and loads
/// the native recognizer, so the first call after app start pays the
/// bootstrap cost once.
final speechRecognizerProvider = FutureProvider<SpeechRecognizer>((ref) async {
  final bootstrap = ref.watch(modelBootstrapProvider);
  final paths = await bootstrap.ensureParakeet();
  final runner = ParakeetRunner(paths: paths);
  final loaded = await runner.load();
  switch (loaded) {
    case Ok():
      break;
    case Err(:final error):
      throw StateError('Parakeet load failed: ${error.message}');
  }
  ref.onDispose(runner.dispose);
  return runner;
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

/// Recording stopped; ASR is transcribing before the row lands on disk.
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
    required Future<SpeechRecognizer> recognizerFuture,
  }) : _recorder = recorder,
       _repository = repository,
       _recognizerFuture = recognizerFuture,
       super(const RecordingIdle());

  final AudioRecorder _recorder;
  final VoiceLogRepository _repository;
  final Future<SpeechRecognizer> _recognizerFuture;
  final _log = Logger('recording_controller');

  Timer? _elapsedTimer;
  DateTime? _startedAt;

  /// Begin a new recording session. No-op if already recording.
  Future<void> start() async {
    if (state is! RecordingIdle && state is! RecordingFailed) return;
    final dir = await getApplicationDocumentsDirectory();
    final audioDir = Directory(p.join(dir.path, 'audio'));
    if (!audioDir.existsSync()) audioDir.createSync(recursive: true);
    final id = 'log_${DateTime.now().microsecondsSinceEpoch}';
    final path = p.join(audioDir.path, '$id.wav');

    final started = await _recorder.start(destinationPath: path);
    switch (started) {
      case Ok():
        break;
      case Err(:final error):
        state = RecordingFailed(error.message);
        return;
    }

    _startedAt = DateTime.now();
    state = const RecordingActive(0);
    _elapsedTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      final startedAt = _startedAt;
      if (startedAt == null) return;
      final elapsed = DateTime.now().difference(startedAt).inMilliseconds;
      state = RecordingActive(elapsed);
    });
  }

  /// Stop, transcribe, persist, and return to idle. The UI transitions
  /// through [RecordingTranscribing] while ASR runs.
  Future<void> stop() async {
    _elapsedTimer?.cancel();
    _elapsedTimer = null;
    if (state is! RecordingActive) return;

    final clip = await _recorder.stop();
    final RecordedClip recorded;
    switch (clip) {
      case Ok(:final value):
        recorded = value;
      case Err(:final error):
        state = RecordingFailed(error.message);
        _startedAt = null;
        return;
    }

    state = const RecordingTranscribing();

    String rawTranscript = '';
    try {
      final recognizer = await _recognizerFuture;
      final txt = await recognizer.transcribeWav(recorded.wavBytes);
      switch (txt) {
        case Ok(:final value):
          rawTranscript = value;
        case Err(:final error):
          _log.w('Transcription failed: ${error.message}');
      }
    } on Object catch (e, s) {
      _log.w('Transcription error', error: e, stack: s);
    }

    final docs = await getApplicationDocumentsDirectory();
    final relPath = p.relative(recorded.audioPath, from: docs.path);

    final inserted = await _repository.insertRecorded(
      id: p.basenameWithoutExtension(recorded.audioPath),
      createdAt: _startedAt ?? DateTime.now(),
      durationMs: recorded.durationMs,
      audioPath: relPath,
      rawTranscript: rawTranscript,
    );
    switch (inserted) {
      case Ok():
        break;
      case Err(:final error):
        state = RecordingFailed(error.message);
        return;
    }

    _startedAt = null;
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
    StateNotifierProvider<RecordingController, RecordingState>((ref) {
      final recorder = ref.watch(audioRecorderProvider);
      final repo = ref.watch(voiceLogRepositoryProvider);
      final recognizerFuture = ref.watch(speechRecognizerProvider.future);
      return RecordingController(
        recorder: recorder,
        repository: repo,
        recognizerFuture: recognizerFuture,
      );
    });
