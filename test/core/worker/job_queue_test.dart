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
