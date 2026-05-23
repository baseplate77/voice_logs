import 'package:drift/drift.dart';

import '../db/database.dart';
import '../db/job_state.dart';
import '../db/processing_state.dart';

/// One claimed job ready for a [JobHandler] to process.
class QueuedJob {
  const QueuedJob({
    required this.id,
    required this.logId,
    required this.jobType,
    required this.attempts,
  });

  /// Job row id.
  final String id;

  /// The voice log this job operates on.
  final String logId;

  /// Kind of job.
  final JobType jobType;

  /// Retry counter at claim time.
  final int attempts;
}

/// Thin persistent queue over the [ProcessingJobs] drift table.
///
/// Jobs are durable: `pending` survives process death, `running` is reset
/// to `pending` on worker start, and missing jobs are reconstructed from
/// `voice_logs.processing_state` so a cut app resumes the pipeline next
/// launch.
class JobQueue {
  JobQueue(this._db);

  final VoxSynthDatabase _db;

  /// Insert a new pending job for [logId]. Returns the new row id.
  ///
  /// Idempotent for active work: if the same [type] for [logId] is already
  /// `pending` or `running`, its id is returned instead of creating a
  /// duplicate. Failed/done historical rows are left untouched so manual
  /// retry can enqueue a fresh attempt.
  Future<String> enqueue({
    required String logId,
    required JobType type,
    int priority = 100,
  }) async {
    final active = await _activeJobId(logId: logId, type: type);
    if (active != null) return active;

    final id = 'job_${DateTime.now().microsecondsSinceEpoch}_${type.wire}';
    final row = ProcessingJob(
      id: id,
      logId: logId,
      jobType: type.wire,
      priority: priority,
      enqueuedAt: DateTime.now().millisecondsSinceEpoch,
      state: JobState.pending.wire,
      attempts: 0,
    );
    await _db.into(_db.processingJobs).insert(row);
    return id;
  }

  /// Transition the highest-priority pending job to `running` and return
  /// it, or `null` if the queue is empty.
  ///
  /// Atomic with respect to multiple workers: we only claim the selected
  /// row if it is still pending at update time.
  Future<QueuedJob?> claimNext() async {
    return _db.transaction(() async {
      final query = _db.select(_db.processingJobs)
        ..where((t) => t.state.equals(JobState.pending.wire))
        ..orderBy([
          (t) => OrderingTerm.asc(t.priority),
          (t) => OrderingTerm.asc(t.enqueuedAt),
        ])
        ..limit(1);
      final row = await query.getSingleOrNull();
      if (row == null) return null;

      final claimed =
          await (_db.update(_db.processingJobs)..where(
                (t) =>
                    t.id.equals(row.id) & t.state.equals(JobState.pending.wire),
              ))
              .write(
                ProcessingJobsCompanion(state: Value(JobState.running.wire)),
              );
      if (claimed == 0) {
        // Another worker claimed this row first.
        return null;
      }

      final type = JobType.fromWireOrNull(row.jobType);
      if (type == null) {
        // Unknown job type — mark failed so it doesn't block the queue.
        await markFailed(row.id);
        return null;
      }
      return QueuedJob(
        id: row.id,
        logId: row.logId,
        jobType: type,
        attempts: row.attempts,
      );
    });
  }

  /// Reset any jobs left in `running` (e.g. from an app crash) back to
  /// `pending` so the worker picks them up on next start.
  Future<int> recoverStale() async {
    return (_db.update(_db.processingJobs)
          ..where((t) => t.state.equals(JobState.running.wire)))
        .write(ProcessingJobsCompanion(state: Value(JobState.pending.wire)));
  }

  /// Recreate missing pipeline jobs from durable voice-log state.
  ///
  /// This closes crash windows such as: log inserted but refine not enqueued,
  /// refined text saved but embed not enqueued, or embeddings saved but the
  /// canonicalize job was cut before it could link mentions.
  Future<int> recoverIncompletePipeline() async {
    var enqueued = 0;
    final rows =
        await (_db.select(_db.voiceLogs)
              ..where(
                (t) => t.processingState.isIn([
                  ProcessingState.transcribing.wire,
                  ProcessingState.recorded.wire,
                  ProcessingState.refined.wire,
                  ProcessingState.embedded.wire,
                ]),
              )
              ..orderBy([(t) => OrderingTerm.asc(t.createdAt)]))
            .get();

    for (final row in rows) {
      final state = ProcessingState.fromWire(row.processingState);
      final type = switch (state) {
        ProcessingState.transcribing => JobType.transcribe,
        ProcessingState.recorded => JobType.refine,
        ProcessingState.refined => JobType.embed,
        ProcessingState.embedded =>
          await _hasUnlinkedMentions(row.id)
              ? JobType.canonicalize
              : await _hasAnyJobForLogType(row.id, JobType.action)
              ? null
              : JobType.action,
        ProcessingState.failed => null,
      };
      if (type == null) continue;
      if (await _hasActiveJobForLog(row.id)) continue;
      await enqueue(logId: row.id, type: type);
      enqueued++;
    }
    return enqueued;
  }

  Future<void> markDone(String jobId) async {
    await (_db.update(_db.processingJobs)..where((t) => t.id.equals(jobId)))
        .write(ProcessingJobsCompanion(state: Value(JobState.done.wire)));
  }

  Future<void> markFailed(String jobId) async {
    await (_db.update(_db.processingJobs)..where((t) => t.id.equals(jobId)))
        .write(ProcessingJobsCompanion(state: Value(JobState.failed.wire)));
  }

  /// Transition a running job back to pending and bump `attempts`.
  /// The worker's retry policy decides when to call this vs [markFailed].
  Future<void> retryLater(String jobId, {required int currentAttempts}) async {
    await (_db.update(
      _db.processingJobs,
    )..where((t) => t.id.equals(jobId))).write(
      ProcessingJobsCompanion(
        state: Value(JobState.pending.wire),
        attempts: Value(currentAttempts + 1),
      ),
    );
  }

  Future<String?> _activeJobId({
    required String logId,
    required JobType type,
  }) async {
    final row =
        await (_db.select(_db.processingJobs)
              ..where(
                (t) =>
                    t.logId.equals(logId) &
                    t.jobType.equals(type.wire) &
                    t.state.isIn([
                      JobState.pending.wire,
                      JobState.running.wire,
                    ]),
              )
              ..orderBy([(t) => OrderingTerm.asc(t.enqueuedAt)])
              ..limit(1))
            .getSingleOrNull();
    return row?.id;
  }

  /// Whether any pending or running jobs exist in the queue.
  Future<bool> hasActiveJobs() async {
    final row =
        await (_db.select(_db.processingJobs)
              ..where(
                (t) => t.state.isIn([
                  JobState.pending.wire,
                  JobState.running.wire,
                ]),
              )
              ..limit(1))
            .getSingleOrNull();
    return row != null;
  }

  Future<bool> _hasAnyJobForLogType(String logId, JobType type) async {
    final row =
        await (_db.select(_db.processingJobs)
              ..where(
                (t) => t.logId.equals(logId) & t.jobType.equals(type.wire),
              )
              ..limit(1))
            .getSingleOrNull();
    return row != null;
  }

  Future<bool> _hasActiveJobForLog(String logId) async {
    final row =
        await (_db.select(_db.processingJobs)
              ..where(
                (t) =>
                    t.logId.equals(logId) &
                    t.state.isIn([
                      JobState.pending.wire,
                      JobState.running.wire,
                    ]),
              )
              ..limit(1))
            .getSingleOrNull();
    return row != null;
  }

  Future<bool> _hasUnlinkedMentions(String logId) async {
    final row =
        await (_db.select(_db.entityMentions)
              ..where(
                (t) => t.logId.equals(logId) & t.canonicalEntityId.isNull(),
              )
              ..limit(1))
            .getSingleOrNull();
    return row != null;
  }
}
