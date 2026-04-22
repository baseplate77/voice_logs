import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:voxsynth/core/db/database.dart';
import 'package:voxsynth/core/db/job_state.dart';
import 'package:voxsynth/core/db/repositories/voice_log_repository.dart';
import 'package:voxsynth/core/result.dart';
import 'package:voxsynth/core/worker/job_queue.dart';
import 'package:voxsynth/features/record/audio_recorder.dart';
import 'package:voxsynth/features/record/recording_providers.dart';
import 'package:voxsynth/features/record/speech_recognizer.dart';

class _FakePathProvider extends Fake
    with MockPlatformInterfaceMixin
    implements PathProviderPlatform {
  @override
  Future<String?> getApplicationDocumentsPath() async =>
      Directory.systemTemp.createTempSync('voxsynth_test_').path;
}

class _FakeRecorder implements AudioRecorder {
  bool started = false;
  String? pathSeen;

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
    return Ok(
      RecordedClip(
        wavBytes: Uint8List.fromList(const [0, 0, 0, 0]),
        audioPath: pathSeen!,
        durationMs: 1500,
      ),
    );
  }

  @override
  Future<void> dispose() async {}
}

class _FakeRecognizer implements SpeechRecognizer {
  _FakeRecognizer(this.output);
  final String output;

  @override
  Future<Result<void, AsrError>> load() async => const Ok(null);

  @override
  Future<Result<String, AsrError>> transcribeWav(Uint8List wavBytes) async =>
      Ok(output);

  @override
  Future<void> dispose() async {}
}

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    PathProviderPlatform.instance = _FakePathProvider();
  });

  test('start → stop persists a VoiceLog with the transcribed text', () async {
    final db = VoxSynthDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final repo = VoiceLogRepository(db);
    final recorder = _FakeRecorder();
    final recognizer = _FakeRecognizer('hello there');

    final controller = RecordingController(
      recorder: recorder,
      repository: repo,
      recognizerFuture: Future.value(recognizer),
      jobQueue: JobQueue(db),
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

    // A refine job should have been enqueued.
    final claimed = await JobQueue(db).claimNext();
    expect(claimed, isNotNull);
    expect(claimed!.jobType, JobType.refine);
  });

  test('stop without start is a no-op', () async {
    final db = VoxSynthDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final repo = VoiceLogRepository(db);
    final controller = RecordingController(
      recorder: _FakeRecorder(),
      repository: repo,
      recognizerFuture: Future.value(_FakeRecognizer('')),
      jobQueue: JobQueue(db),
    );
    addTearDown(controller.dispose);

    await controller.stop();
    final rows = await repo.watchAll().first;
    expect(rows, isEmpty);
  });
}
