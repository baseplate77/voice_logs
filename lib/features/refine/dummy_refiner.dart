import '../../core/app_error.dart';
import '../../core/db/job_state.dart';
import '../../core/db/repositories/voice_log_repository.dart';
import '../../core/result.dart';
import '../../core/worker/job_handler.dart';

/// Stand-in refine handler — copies `raw_transcript` → `cleaned_text`
/// after a configurable delay. Replaced by the real Gemma pipeline in
/// Phase 4. Keeping the behavior here lets the UI update path be
/// exercised end-to-end before the heavy LLM dep lands.
class DummyRefiner implements JobHandler {
  DummyRefiner({
    required this.repository,
    this.delay = const Duration(seconds: 5),
  });

  final VoiceLogRepository repository;
  final Duration delay;

  @override
  JobType get type => JobType.refine;

  @override
  Future<Result<JobOutcome, AppError>> handle(JobContext ctx) async {
    await Future<void>.delayed(delay);
    final log = await repository.find(ctx.logId);
    if (log == null) {
      return const Ok(JobFailedPermanently('log not found'));
    }
    final res = await repository.markRefined(
      id: ctx.logId,
      cleanedText: log.rawTranscript,
    );
    return switch (res) {
      Ok() => const Ok(JobSucceeded()),
      Err(:final error) => Err(error),
    };
  }
}
