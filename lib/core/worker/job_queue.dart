import 'package:drift/drift.dart';

import '../db/database.dart';
import '../db/job_state.dart';

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

/// Thin persistent queue over the [ProcessingJobs] drift table. A small
/// surface — just enqueue / claim / complete — so tests don't wrestle
/// with query builders.
class JobQueue {
  JobQueue(this._db);

  final VoxSynthDatabase _db;

  /// Insert a new pending job for [logId]. Returns the new row id.
  Future<String> enqueue({
    required String logId,
    required JobType type,
    int priority = 100,
  }) async {
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

  /// Transition the lowest-priority pending job to `running` and return
  /// it, or `null` if the queue is empty. Not atomic w.r.t. multiple
  /// workers — Phase 2 assumes a single worker isolate.
  Future<QueuedJob?> claimNext() async {
    final query = _db.select(_db.processingJobs)
      ..where((t) => t.state.equals(JobState.pending.wire))
      ..orderBy([
        (t) => OrderingTerm.asc(t.priority),
        (t) => OrderingTerm.asc(t.enqueuedAt),
      ])
      ..limit(1);
    final row = await query.getSingleOrNull();
    if (row == null) return null;

    await (_db.update(_db.processingJobs)..where((t) => t.id.equals(row.id)))
        .write(ProcessingJobsCompanion(state: Value(JobState.running.wire)));

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
  }

  /// Reset any jobs left in `running` (e.g. from an app crash) back to
  /// `pending` so the worker picks them up on next start.
  Future<int> recoverStale() async {
    return (_db.update(_db.processingJobs)
          ..where((t) => t.state.equals(JobState.running.wire)))
        .write(ProcessingJobsCompanion(state: Value(JobState.pending.wire)));
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
}
