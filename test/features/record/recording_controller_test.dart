import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voxsynth/core/db/database.dart';
import 'package:voxsynth/core/db/job_state.dart';
import 'package:voxsynth/core/db/repositories/voice_log_repository.dart';
import 'package:voxsynth/core/result.dart';
import 'package:voxsynth/core/worker/job_queue.dart';
import 'package:voxsynth/features/record/audio_recorder.dart';
import 'package:voxsynth/features/record/recording_providers.dart';

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

String tmpDocs() => Directory.systemTemp.createTempSync('voxsynth_test_').path;

void main() {
  setUpAll(TestWidgetsFlutterBinding.ensureInitialized);

  test(
    'start → stop inserts a transcribing-state log and enqueues transcribe',
    () async {
      final db = VoxSynthDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final repo = VoiceLogRepository(db);
      final recorder = _FakeRecorder();

      final controller = RecordingController(
        recorder: recorder,
        repository: repo,
        jobQueue: JobQueue(db),
        docsPath: tmpDocs(),
      );
      addTearDown(controller.dispose);

      await controller.start();
      expect(recorder.started, isTrue);
      expect(controller.state, isA<RecordingActive>());

      await controller.stop();

      final rows = await repo.watchAll().first;
      expect(rows, hasLength(1));
      // Transcription has been deferred to the worker — the raw transcript
      // is empty for now and the row is in the transcribing state so the
      // home list shows the "Transcribing…" indicator.
      expect(rows.first.rawTranscript, '');
      expect(rows.first.processingState.wire, 'transcribing');
      expect(controller.state, isA<RecordingIdle>());

      final claimed = await JobQueue(db).claimNext();
      expect(claimed, isNotNull);
      expect(claimed!.jobType, JobType.transcribe);
    },
  );

  test('stop immediately shows transcribing while audio finalizes', () async {
    final db = VoxSynthDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final repo = VoiceLogRepository(db);
    final recorder = _BlockingStopRecorder();

    final controller = RecordingController(
      recorder: recorder,
      repository: repo,
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

  test('stop without start is a no-op', () async {
    final db = VoxSynthDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final repo = VoiceLogRepository(db);
    final controller = RecordingController(
      recorder: _FakeRecorder(),
      repository: repo,
      jobQueue: JobQueue(db),
      docsPath: tmpDocs(),
    );
    addTearDown(controller.dispose);

    await controller.stop();
    final rows = await repo.watchAll().first;
    expect(rows, isEmpty);
  });
}
