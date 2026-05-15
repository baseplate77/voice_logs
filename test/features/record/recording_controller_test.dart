import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voxsynth/core/db/database.dart';
import 'package:voxsynth/core/db/job_state.dart';
import 'package:voxsynth/core/db/repositories/transcript_segment_repository.dart';
import 'package:voxsynth/core/db/repositories/voice_log_repository.dart';
import 'package:voxsynth/core/result.dart';
import 'package:voxsynth/core/worker/job_queue.dart';
import 'package:voxsynth/features/record/audio_recorder.dart';
import 'package:voxsynth/features/record/recording_providers.dart';
import 'package:voxsynth/features/record/speech_recognizer.dart';

class _FakeRecorder implements AudioRecorder {
  bool started = false;
  String? pathSeen;
  final _pcm = StreamController<Uint8List>.broadcast();

  @override
  Stream<Uint8List> get pcm16Stream => _pcm.stream;

  @override
  Future<bool> hasPermission() async => true;

  @override
  Future<Result<void, CaptureError>> start({
    required String destinationPath,
  }) async {
    started = true;
    pathSeen = destinationPath;
    return const Ok(null);
  }

  @override
  Future<Result<RecordedClip, CaptureError>> stop() async {
    if (!started) {
      return const Err(RecorderStateError('not started'));
    }
    started = false;
    return Ok(RecordedClip(audioPath: pathSeen!, durationMs: 1500));
  }

  @override
  Future<void> dispose() async {
    await _pcm.close();
  }
}

class _BlockingStopRecorder implements AudioRecorder {
  bool started = false;
  String? pathSeen;
  final _pcm = StreamController<Uint8List>.broadcast();
  final _stopCompleter = Completer<Result<RecordedClip, CaptureError>>();

  @override
  Stream<Uint8List> get pcm16Stream => _pcm.stream;

  @override
  Future<bool> hasPermission() async => true;

  @override
  Future<Result<void, CaptureError>> start({
    required String destinationPath,
  }) async {
    started = true;
    pathSeen = destinationPath;
    return const Ok(null);
  }

  @override
  Future<Result<RecordedClip, CaptureError>> stop() => _stopCompleter.future;

  void completeStop() {
    started = false;
    _stopCompleter.complete(
      Ok(RecordedClip(audioPath: pathSeen!, durationMs: 1500)),
    );
  }

  @override
  Future<void> dispose() async {
    await _pcm.close();
  }
}

class _FakeRecognizer implements SpeechRecognizer {
  _FakeRecognizer(this.output);
  final String output;
  bool disposed = false;

  @override
  Future<Result<void, AsrError>> load() async => const Ok(null);

  @override
  Future<Result<String, AsrError>> transcribeFile(String wavPath) async =>
      Ok(output);

  @override
  Future<Result<TranscriptionResult, AsrError>> transcribeFileDetailed(
    String wavPath,
  ) async => Ok(TranscriptionResult.textOnly(output));

  @override
  Future<void> dispose() async {
    disposed = true;
  }
}

class _FakeStreamingRecognizer implements StreamingSpeechRecognizer {
  int beginStreamCalls = 0;
  int chunks = 0;
  int finishStreamCalls = 0;
  int fileTranscriptions = 0;

  @override
  Future<Result<void, AsrError>> beginStream() async {
    beginStreamCalls++;
    return const Ok(null);
  }

  @override
  Future<Result<String, AsrError>> acceptPcm16(
    Uint8List chunk, {
    int sampleRate = 16000,
  }) async {
    chunks++;
    return const Ok('live partial');
  }

  @override
  Future<Result<String, AsrError>> finishStream() async {
    finishStreamCalls++;
    return const Ok('live final');
  }

  @override
  Future<Result<void, AsrError>> load() async => const Ok(null);

  @override
  Future<Result<String, AsrError>> transcribeFile(String wavPath) async {
    fileTranscriptions++;
    return const Ok('file transcript');
  }

  @override
  Future<Result<TranscriptionResult, AsrError>> transcribeFileDetailed(
    String wavPath,
  ) async {
    fileTranscriptions++;
    return Ok(TranscriptionResult.textOnly('file transcript'));
  }

  @override
  Future<void> dispose() async {}
}

String tmpDocs() => Directory.systemTemp.createTempSync('voxsynth_test_').path;

void main() {
  setUpAll(TestWidgetsFlutterBinding.ensureInitialized);

  test('start → stop persists a VoiceLog with the transcribed text', () async {
    final db = VoxSynthDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final repo = VoiceLogRepository(db);
    final recorder = _FakeRecorder();
    final recognizer = _FakeRecognizer('hello there');

    final controller = RecordingController(
      recorder: recorder,
      repository: repo,
      segmentRepository: TranscriptSegmentRepository(db),
      recognizerFactory: () async => recognizer,
      jobQueue: JobQueue(db),
      docsPath: tmpDocs(),
    );
    addTearDown(controller.dispose);

    await controller.start();
    expect(recorder.started, isTrue);
    expect(controller.state, isA<RecordingActive>());

    await controller.stop();

    // Wait for async transcription + insert to finish.
    await Future<void>.delayed(const Duration(milliseconds: 20));

    final rows = await repo.watchAll().first;
    expect(rows, hasLength(1));
    expect(rows.first.rawTranscript, 'hello there');
    expect(controller.state, isA<RecordingIdle>());
    expect(recognizer.disposed, isTrue);

    // A refine job should have been enqueued.
    final claimed = await JobQueue(db).claimNext();
    expect(claimed, isNotNull);
    expect(claimed!.jobType, JobType.refine);
  });

  test('stop immediately shows transcribing while audio finalizes', () async {
    final db = VoxSynthDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final repo = VoiceLogRepository(db);
    final recorder = _BlockingStopRecorder();
    final recognizer = _FakeRecognizer('hello there');

    final controller = RecordingController(
      recorder: recorder,
      repository: repo,
      segmentRepository: TranscriptSegmentRepository(db),
      recognizerFactory: () async => recognizer,
      jobQueue: JobQueue(db),
      docsPath: tmpDocs(),
    );
    addTearDown(controller.dispose);

    await controller.start();
    expect(controller.state, isA<RecordingActive>());

    final stopped = controller.stop();
    expect(controller.state, isA<RecordingTranscribing>());

    recorder.completeStop();
    await stopped;
    expect(controller.state, isA<RecordingIdle>());
  });

  test(
    'streaming recognizer is used only for completed-file transcription',
    () async {
      final db = VoxSynthDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final repo = VoiceLogRepository(db);
      final recorder = _FakeRecorder();
      final recognizer = _FakeStreamingRecognizer();

      final controller = RecordingController(
        recorder: recorder,
        repository: repo,
        segmentRepository: TranscriptSegmentRepository(db),
        recognizerFactory: () async => recognizer,
        jobQueue: JobQueue(db),
        docsPath: tmpDocs(),
      );
      addTearDown(controller.dispose);

      await controller.start();
      await Future<void>.delayed(Duration.zero);

      final active = controller.state;
      expect(active, isA<RecordingActive>());

      await controller.stop();

      final rows = await repo.watchAll().first;
      expect(rows.single.rawTranscript, 'file transcript');
      expect(recognizer.beginStreamCalls, 0);
      expect(recognizer.chunks, 0);
      expect(recognizer.finishStreamCalls, 0);
      expect(recognizer.fileTranscriptions, 1);
    },
  );

  test('stop without start is a no-op', () async {
    final db = VoxSynthDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final repo = VoiceLogRepository(db);
    final controller = RecordingController(
      recorder: _FakeRecorder(),
      repository: repo,
      segmentRepository: TranscriptSegmentRepository(db),
      recognizerFactory: () async => _FakeRecognizer(''),
      jobQueue: JobQueue(db),
      docsPath: tmpDocs(),
    );
    addTearDown(controller.dispose);

    await controller.stop();
    final rows = await repo.watchAll().first;
    expect(rows, isEmpty);
  });
}
