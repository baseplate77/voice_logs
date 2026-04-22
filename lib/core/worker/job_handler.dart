import '../app_error.dart';
import '../db/job_state.dart';
import '../result.dart';

/// Result of handling one job — success or a typed failure carrying
/// whether the worker should retry.
sealed class JobOutcome {
  const JobOutcome();
}

/// Job completed; row can be marked `done`.
final class JobSucceeded extends JobOutcome {
  const JobSucceeded();
}

/// Transient failure — retry after backoff up to the retry limit.
final class JobShouldRetry extends JobOutcome {
  const JobShouldRetry(this.reason);
  final String reason;
}

/// Permanent failure — row should be marked `failed`.
final class JobFailedPermanently extends JobOutcome {
  const JobFailedPermanently(this.reason);
  final String reason;
}

/// Context the worker hands to a [JobHandler] when dispatching.
class JobContext {
  const JobContext({
    required this.jobId,
    required this.logId,
    required this.attempts,
  });

  final String jobId;
  final String logId;

  /// How many times the handler has already run for this job.
  final int attempts;
}

/// Strategy interface implemented once per [JobType]. Handlers are
/// registered in the worker's dispatch map.
abstract class JobHandler {
  /// The type this handler claims.
  JobType get type;

  /// Execute the job. Returning an error variant is preferred over
  /// throwing — the worker converts thrown exceptions to
  /// [JobShouldRetry] automatically.
  Future<Result<JobOutcome, AppError>> handle(JobContext ctx);
}
