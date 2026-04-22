import '../../core/app_error.dart';
import '../../core/db/job_state.dart';
import '../../core/db/repositories/voice_log_repository.dart';
import '../../core/result.dart';
import '../../core/worker/job_handler.dart';
import '../search/canonicalizer.dart';

/// `canonicalize` job handler — runs after embed so mentions land on
/// their canonical entities without blocking search. The refine stage
/// already wrote entity mention rows; this stage fills in their
/// `canonical_entity_id`.
class CanonicalizeJobHandler implements JobHandler {
  CanonicalizeJobHandler({
    required this.voiceLogs,
    required this.canonicalizer,
  });

  final VoiceLogRepository voiceLogs;
  final Canonicalizer canonicalizer;

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
      Ok() => const Ok(JobSucceeded()),
      Err(:final error) => Err(error),
    };
  }
}
