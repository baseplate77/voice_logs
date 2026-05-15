import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voxsynth/core/db/database.dart';
import 'package:voxsynth/core/db/job_state.dart';
import 'package:voxsynth/core/db/processing_state.dart';
import 'package:voxsynth/core/db/repositories/voice_log_repository.dart';
import 'package:voxsynth/core/worker/job_queue.dart';

void main() {
  late VoxSynthDatabase db;
  late JobQueue queue;
  late VoiceLogRepository repo;

  setUp(() async {
    db = VoxSynthDatabase(NativeDatabase.memory());
    queue = JobQueue(db);
    repo = VoiceLogRepository(db);
    // A log must exist for the FK constraint.
    await repo.insertRecorded(
      id: 'log_a',
      createdAt: DateTime(2026, 4, 22),
      durationMs: 1000,
      audioPath: 'a.wav',
      rawTranscript: 'hello',
    );
    await repo.insertRecorded(
      id: 'log_b',
      createdAt: DateTime(2026, 4, 23),
      durationMs: 1000,
      audioPath: 'b.wav',
      rawTranscript: 'second',
    );
  });

  tearDown(() => db.close());

  test('enqueue then claimNext transitions pending → running', () async {
    final id = await queue.enqueue(logId: 'log_a', type: JobType.refine);
    final claimed = await queue.claimNext();
    expect(claimed, isNotNull);
    expect(claimed!.id, id);
    expect(claimed.jobType, JobType.refine);
    expect(claimed.attempts, 0);

    // A second claim should return null — the first is now running.
    expect(await queue.claimNext(), isNull);
  });

  test('enqueue is idempotent for pending and running jobs', () async {
    final first = await queue.enqueue(logId: 'log_a', type: JobType.refine);
    final second = await queue.enqueue(logId: 'log_a', type: JobType.refine);
    expect(second, first);

    final claimed = await queue.claimNext();
    expect(claimed!.id, first);
    final third = await queue.enqueue(logId: 'log_a', type: JobType.refine);
    expect(third, first);

    await queue.markDone(first);
    final afterDone = await queue.enqueue(logId: 'log_a', type: JobType.refine);
    expect(afterDone, isNot(first));
  });

  test('same-priority jobs run in FIFO order', () async {
    final first = await queue.enqueue(logId: 'log_a', type: JobType.refine);
    await Future<void>.delayed(const Duration(milliseconds: 1));
    final second = await queue.enqueue(logId: 'log_b', type: JobType.refine);

    expect((await queue.claimNext())!.id, first);
    await queue.markDone(first);
    expect((await queue.claimNext())!.id, second);
  });

  test('retryLater bumps attempts and returns to pending', () async {
    final id = await queue.enqueue(logId: 'log_a', type: JobType.refine);
    final first = await queue.claimNext();
    await queue.retryLater(id, currentAttempts: first!.attempts);
    final second = await queue.claimNext();
    expect(second, isNotNull);
    expect(second!.attempts, 1);
  });

  test('recoverStale resets running jobs to pending', () async {
    await queue.enqueue(logId: 'log_a', type: JobType.refine);
    await queue.claimNext();
    final reset = await queue.recoverStale();
    expect(reset, 1);
    expect(await queue.claimNext(), isNotNull);
  });

  test('recoverIncompletePipeline reconstructs missing refine job', () async {
    final recovered = await queue.recoverIncompletePipeline();
    expect(recovered, 2);
    final first = await queue.claimNext();
    expect(first!.logId, 'log_a');
    expect(first.jobType, JobType.refine);
  });

  test('recoverIncompletePipeline reconstructs missing embed job', () async {
    await repo.markRefined(id: 'log_a', cleanedText: 'Hello.');
    await queue.enqueue(logId: 'log_b', type: JobType.refine);

    final recovered = await queue.recoverIncompletePipeline();
    expect(recovered, 1);

    final first = await queue.claimNext();
    expect(first!.logId, 'log_b');
    await queue.markDone(first.id);
    final second = await queue.claimNext();
    expect(second!.logId, 'log_a');
    expect(second.jobType, JobType.embed);
  });

  test(
    'recoverIncompletePipeline reconstructs missing action job once',
    () async {
      await repo.markEmbedded('log_a');
      await repo.markEmbedded('log_b');
      final historical = await queue.enqueue(
        logId: 'log_b',
        type: JobType.action,
      );
      await queue.claimNext();
      await queue.markDone(historical);

      final recovered = await queue.recoverIncompletePipeline();
      expect(recovered, 1);

      final action = await queue.claimNext();
      expect(action!.logId, 'log_a');
      expect(action.jobType, JobType.action);
      await queue.markDone(action.id);

      expect(await queue.recoverIncompletePipeline(), 0);
    },
  );

  test('lower priority jobs run first', () async {
    final high = await queue.enqueue(logId: 'log_a', type: JobType.refine);
    final low = await queue.enqueue(
      logId: 'log_a',
      type: JobType.embed,
      priority: 10,
    );
    final first = await queue.claimNext();
    expect(first!.id, low);
    expect(first.jobType, JobType.embed);
    await queue.markDone(low);
    final second = await queue.claimNext();
    expect(second!.id, high);
  });

  test('markRefined updates the voice log state', () async {
    final res = await repo.markRefined(id: 'log_a', cleanedText: 'Hello.');
    expect(res.isOk, isTrue);
    final fetched = await repo.find('log_a');
    expect(fetched!.cleanedText, 'Hello.');
    expect(fetched.processingState, ProcessingState.refined);
  });
}
