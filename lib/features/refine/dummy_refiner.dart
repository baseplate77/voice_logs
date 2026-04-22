import '../../core/app_error.dart';
import '../../core/db/job_state.dart';
import '../../core/db/repositories/voice_log_repository.dart';
import '../../core/result.dart';
import '../../core/worker/job_handler.dart';
import '../../core/worker/job_queue.dart';

/// Stand-in refine handler — copies `raw_transcript` → `cleaned_text`
/// after a configurable delay, then enqueues the downstream `embed`
/// job. Replaced by the real Gemma pipeline in Phase 4; the embed
/// hand-off survives the swap.
class DummyRefiner implements JobHandler {
  DummyRefiner({
    required this.repository,
    required this.queue,
    this.delay = const Duration(seconds: 5),
  });

  final VoiceLogRepository repository;
  final JobQueue queue;
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
    switch (res) {
      case Ok():
        await queue.enqueue(logId: ctx.logId, type: JobType.embed);
        return const Ok(JobSucceeded());
      case Err(:final error):
        return Err(error);
    }
  }
}
