import '../../core/app_error.dart';
import '../../core/db/job_state.dart';
import '../../core/db/repositories/entity_mention_repository.dart';
import '../../core/db/repositories/voice_log_repository.dart';
import '../../core/result.dart';
import '../../core/worker/job_handler.dart';
import '../../core/worker/job_queue.dart';
import '../search/canonicalizer.dart';

/// `canonicalize` job handler — runs after embed so mentions land on
/// their canonical entities without blocking search. The refine stage
/// already wrote entity mention rows; this stage fills in their
/// `canonical_entity_id`.
class CanonicalizeJobHandler implements JobHandler {
  CanonicalizeJobHandler({
    required this.voiceLogs,
    required this.canonicalizer,
    required this.queue,
    required this.mentions,
  });

  final VoiceLogRepository voiceLogs;
  final Canonicalizer canonicalizer;
  final JobQueue queue;
  final EntityMentionRepository mentions;

  @override
  JobType get type => JobType.canonicalize;

  @override
  Future<Result<JobOutcome, AppError>> handle(JobContext ctx) async {
    final log = await voiceLogs.find(ctx.logId);
    if (log == null) {
      return const Ok(JobFailedPermanently('log not found'));
    }
    final cleaned = log.cleanedText ?? log.rawTranscript;
    final res = await canonicalizer.canonicalizeLog(
      logId: ctx.logId,
      cleanedText: cleaned,
    );
    return switch (res) {
      Ok() => await _enqueueFollowUpJobs(ctx.logId),
      Err(:final error) => Err(error),
    };
  }

  Future<Result<JobOutcome, AppError>> _enqueueFollowUpJobs(
    String logId,
  ) async {
    // Actions are user-facing and time-sensitive, so enqueue before memory.
    await queue.enqueue(logId: logId, type: JobType.action, priority: 90);
    await queue.enqueue(logId: logId, type: JobType.memory);

    // Entity-summary jobs run per canonical entity, not per log. We reuse
    // the queue's `logId` column as a target id — see EntitySummaryJobHandler
    // for the polymorphism note. The handler itself checks freshness via
    // EntitySummaryRepository.needsRegeneration so over-enqueueing is safe
    // (a dedup-friendly no-op when the summary is still fresh).
    final newlyLinked = await mentions.forLog(logId);
    final entityIds = <String>{
      for (final m in newlyLinked)
        if (m.canonicalEntityId != null) m.canonicalEntityId!,
    };
    for (final id in entityIds) {
      await queue.enqueue(logId: id, type: JobType.entitySummary);
    }
    return const Ok(JobSucceeded());
  }
}
