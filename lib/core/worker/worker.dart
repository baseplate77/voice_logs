import 'dart:async';

import '../db/job_state.dart';
import '../logger.dart';
import '../result.dart';
import 'job_handler.dart';
import 'job_queue.dart';

/// Single-consumer worker that polls [JobQueue] and dispatches jobs to
/// registered [JobHandler]s.
///
/// Phase 2 runs the worker on the main isolate — simple, and plenty
/// responsive for dummy jobs. Phase 4+ will move the heavy lifters
/// (Gemma, e5) into a dedicated isolate behind the same [JobHandler]
/// interface.
class Worker {
  Worker({
    required JobQueue queue,
    required Map<JobType, JobHandler> handlers,
    Duration pollInterval = const Duration(milliseconds: 500),
    int maxAttemptsPerJob = 3,
  }) : _queue = queue,
       _handlers = handlers,
       _pollInterval = pollInterval,
       _maxAttempts = maxAttemptsPerJob;

  final JobQueue _queue;
  final Map<JobType, JobHandler> _handlers;
  final Duration _pollInterval;
  final int _maxAttempts;
  final _log = Logger('worker');

  Timer? _timer;
  bool _busy = false;

  /// Begin polling. Idempotent.
  Future<void> start() async {
    if (_timer != null) return;
    // Recover any jobs left `running` from a crash.
    final recovered = await _queue.recoverStale();
    if (recovered > 0) {
      _log.i('Recovered $recovered stale running jobs');
    }
    _timer = Timer.periodic(_pollInterval, (_) => unawaited(_tick()));
  }

  /// Stop polling. Safe to call any number of times.
  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _tick() async {
    if (_busy) return;
    _busy = true;
    try {
      final job = await _queue.claimNext();
      if (job == null) return;
      await _dispatch(job);
    } finally {
      _busy = false;
    }
  }

  Future<void> _dispatch(QueuedJob job) async {
    final handler = _handlers[job.jobType];
    if (handler == null) {
      _log.w('No handler registered for ${job.jobType.wire}');
      await _queue.markFailed(job.id);
      return;
    }

    JobOutcome outcome;
    try {
      final res = await handler.handle(
        JobContext(jobId: job.id, logId: job.logId, attempts: job.attempts),
      );
      outcome = switch (res) {
        Ok(:final value) => value,
        Err(:final error) => JobShouldRetry(
          'handler returned error: ${error.message}',
        ),
      };
    } on Object catch (e, s) {
      _log.w('Handler threw', error: e, stack: s);
      outcome = JobShouldRetry('threw: $e');
    }

    switch (outcome) {
      case JobSucceeded():
        await _queue.markDone(job.id);
      case JobFailedPermanently(:final reason):
        _log.w('Job ${job.id} permanently failed: $reason');
        await _queue.markFailed(job.id);
      case JobShouldRetry(:final reason):
        if (job.attempts + 1 >= _maxAttempts) {
          _log.w(
            'Job ${job.id} exhausted retries ($_maxAttempts), failing: $reason',
          );
          await _queue.markFailed(job.id);
        } else {
          await _queue.retryLater(job.id, currentAttempts: job.attempts);
        }
    }
  }
}
