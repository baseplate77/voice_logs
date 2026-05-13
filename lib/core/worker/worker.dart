import 'dart:async';

import '../db/job_state.dart';
import '../logger.dart';
import '../pipeline_debug.dart';
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
    Duration Function(QueuedJob job, int nextAttempt, String reason)?
    retryDelay,
    FutureOr<void> Function(QueuedJob job, String reason)? onPermanentFailure,
    FutureOr<void> Function(QueuedJob job)? onJobSucceeded,
    PipelineDebugSink debugSink = const NoopPipelineDebugSink(),
  }) : _queue = queue,
       _handlers = handlers,
       _pollInterval = pollInterval,
       _maxAttempts = maxAttemptsPerJob,
       _retryDelay = retryDelay ?? defaultRetryDelay,
       _onPermanentFailure = onPermanentFailure,
       _onJobSucceeded = onJobSucceeded,
       _debug = debugSink;

  final JobQueue _queue;
  final Map<JobType, JobHandler> _handlers;
  final Duration _pollInterval;
  final int _maxAttempts;
  final Duration Function(QueuedJob job, int nextAttempt, String reason)
  _retryDelay;
  final FutureOr<void> Function(QueuedJob job, String reason)?
  _onPermanentFailure;
  final FutureOr<void> Function(QueuedJob job)? _onJobSucceeded;
  final PipelineDebugSink _debug;
  final _log = Logger('worker');

  Timer? _timer;
  bool _busy = false;

  /// Exponential-ish delay before a transient retry is re-queued.
  static Duration defaultRetryDelay(QueuedJob _, int nextAttempt, String _) {
    final seconds = switch (nextAttempt) {
      1 => 5,
      2 => 15,
      _ => 30,
    };
    return Duration(seconds: seconds);
  }

  /// Begin polling. Idempotent.
  Future<void> start() async {
    if (_timer != null) return;
    // Recover any jobs left `running` from a crash, then reconstruct
    // missing stage jobs from voice_logs.processing_state. This makes the
    // SQL DB the durable source of truth across app kills/restarts.
    final recovered = await _queue.recoverStale();
    if (recovered > 0) {
      _log.i('Recovered $recovered stale running jobs');
      _debug.record(
        stage: PipelineDebugStage.worker,
        event: 'recovered',
        message: 'Recovered $recovered stale running jobs',
      );
    }
    final reconstructed = await _queue.recoverIncompletePipeline();
    if (reconstructed > 0) {
      _log.i('Reconstructed $reconstructed incomplete pipeline jobs');
      _debug.record(
        stage: PipelineDebugStage.worker,
        event: 'reconstructed',
        message: 'Reconstructed $reconstructed incomplete pipeline jobs',
      );
    }
    _timer = Timer.periodic(_pollInterval, (_) => unawaited(_tick()));
    unawaited(_tick());
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
      while (_timer != null) {
        final job = await _queue.claimNext();
        if (job == null) return;
        await _dispatch(job);
      }
    } finally {
      _busy = false;
    }
  }

  Future<void> _dispatch(QueuedJob job) async {
    final watch = Stopwatch()..start();
    final stage = PipelineDebugStage.fromJobType(job.jobType);
    final attempt = job.attempts + 1;
    _debug.record(
      logId: job.logId,
      jobId: job.id,
      stage: stage,
      event: 'started',
      attempt: attempt,
      message: 'Started ${job.jobType.wire} job (attempt $attempt)',
    );

    final handler = _handlers[job.jobType];
    if (handler == null) {
      final reason = 'No handler registered for ${job.jobType.wire}';
      _log.w(reason);
      _debug.record(
        logId: job.logId,
        jobId: job.id,
        stage: stage,
        event: 'failed',
        attempt: attempt,
        elapsedMs: watch.elapsedMilliseconds,
        message: reason,
      );
      await _failPermanently(job, reason);
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
        _debug.record(
          logId: job.logId,
          jobId: job.id,
          stage: stage,
          event: 'succeeded',
          attempt: attempt,
          elapsedMs: watch.elapsedMilliseconds,
          message: 'Completed ${job.jobType.wire} job',
        );
        await _onJobSucceeded?.call(job);
      case JobFailedPermanently(:final reason):
        _log.w('Job ${job.id} permanently failed: $reason');
        _debug.record(
          logId: job.logId,
          jobId: job.id,
          stage: stage,
          event: 'failed',
          attempt: attempt,
          elapsedMs: watch.elapsedMilliseconds,
          message: reason,
        );
        await _failPermanently(job, reason);
      case JobShouldRetry(:final reason):
        if (job.attempts + 1 >= _maxAttempts) {
          final exhausted =
              'Job ${job.id} exhausted retries ($_maxAttempts): $reason';
          _log.w(exhausted);
          _debug.record(
            logId: job.logId,
            jobId: job.id,
            stage: stage,
            event: 'failed',
            attempt: attempt,
            elapsedMs: watch.elapsedMilliseconds,
            message: exhausted,
          );
          await _failPermanently(job, exhausted);
        } else {
          final delay = _retryDelay(job, attempt, reason);
          if (delay > Duration.zero) {
            _debug.record(
              logId: job.logId,
              jobId: job.id,
              stage: stage,
              event: 'retry_wait',
              attempt: attempt,
              elapsedMs: watch.elapsedMilliseconds,
              message: 'Retrying after ${delay.inMilliseconds} ms: $reason',
            );
            await Future<void>.delayed(delay);
          }
          await _queue.retryLater(job.id, currentAttempts: job.attempts);
          _debug.record(
            logId: job.logId,
            jobId: job.id,
            stage: stage,
            event: 'retrying',
            attempt: attempt,
            elapsedMs: watch.elapsedMilliseconds,
            message: reason,
          );
        }
    }
  }

  Future<void> _failPermanently(QueuedJob job, String reason) async {
    await _queue.markFailed(job.id);
    await _onPermanentFailure?.call(job, reason);
  }
}
