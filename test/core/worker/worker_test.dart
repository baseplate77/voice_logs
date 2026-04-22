import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voxsynth/core/app_error.dart';
import 'package:voxsynth/core/db/database.dart';
import 'package:voxsynth/core/db/job_state.dart';
import 'package:voxsynth/core/db/processing_state.dart';
import 'package:voxsynth/core/db/repositories/voice_log_repository.dart';
import 'package:voxsynth/core/result.dart';
import 'package:voxsynth/core/worker/job_handler.dart';
import 'package:voxsynth/core/worker/job_queue.dart';
import 'package:voxsynth/core/worker/worker.dart';
import 'package:voxsynth/features/refine/dummy_refiner.dart';

void main() {
  group('DummyRefiner', () {
    late VoxSynthDatabase db;
    late VoiceLogRepository repo;

    setUp(() async {
      db = VoxSynthDatabase(NativeDatabase.memory());
      repo = VoiceLogRepository(db);
      await repo.insertRecorded(
        id: 'log_1',
        createdAt: DateTime(2026, 4, 22),
        durationMs: 1000,
        audioPath: 'a.wav',
        rawTranscript: 'raw words',
      );
    });

    tearDown(() => db.close());

    test('copies raw → cleaned and returns JobSucceeded', () async {
      final handler = DummyRefiner(repository: repo, delay: Duration.zero);
      final res = await handler.handle(
        const JobContext(jobId: 'j1', logId: 'log_1', attempts: 0),
      );
      expect(res, isA<Ok<JobOutcome, AppError>>());
      final log = await repo.find('log_1');
      expect(log!.cleanedText, 'raw words');
      expect(log.processingState, ProcessingState.refined);
    });
  });

  group('Worker', () {
    late VoxSynthDatabase db;
    late JobQueue queue;
    late VoiceLogRepository repo;

    setUp(() async {
      db = VoxSynthDatabase(NativeDatabase.memory());
      queue = JobQueue(db);
      repo = VoiceLogRepository(db);
      await repo.insertRecorded(
        id: 'log_1',
        createdAt: DateTime(2026, 4, 22),
        durationMs: 1000,
        audioPath: 'a.wav',
        rawTranscript: 'raw words',
      );
    });

    tearDown(() => db.close());

    test('picks up a refine job and succeeds', () async {
      await queue.enqueue(logId: 'log_1', type: JobType.refine);
      final worker = Worker(
        queue: queue,
        handlers: {
          JobType.refine: DummyRefiner(repository: repo, delay: Duration.zero),
        },
        pollInterval: const Duration(milliseconds: 10),
      );
      await worker.start();
      // Give the worker a tick or two.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      worker.stop();
      final log = await repo.find('log_1');
      expect(log!.processingState, ProcessingState.refined);
    });

    test('retries then fails when handler always errors', () async {
      await queue.enqueue(logId: 'log_1', type: JobType.refine);
      final worker = Worker(
        queue: queue,
        handlers: {JobType.refine: _AlwaysFails()},
        pollInterval: const Duration(milliseconds: 5),
        maxAttemptsPerJob: 2,
      );
      await worker.start();
      await Future<void>.delayed(const Duration(milliseconds: 80));
      worker.stop();
      final log = await repo.find('log_1');
      // Log still in 'recorded' state — refine never completed.
      expect(log!.processingState, ProcessingState.recorded);
    });
  });
}

class _AlwaysFails implements JobHandler {
  @override
  JobType get type => JobType.refine;

  @override
  Future<Result<JobOutcome, AppError>> handle(JobContext ctx) async {
    throw StateError('boom');
  }
}
