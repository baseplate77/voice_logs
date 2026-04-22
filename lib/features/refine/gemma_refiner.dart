import '../../core/app_error.dart';
import '../../core/db/job_state.dart';
import '../../core/db/repositories/entity_mention_repository.dart';
import '../../core/db/repositories/voice_log_repository.dart';
import '../../core/logger.dart';
import '../../core/result.dart';
import '../../core/worker/job_handler.dart';
import '../../core/worker/job_queue.dart';
import 'llm_runner.dart';
import 'offset_recovery.dart';
import 'prompt_templates.dart';
import 'response_parser.dart';

/// Refine handler that drives the real Gemma pipeline. Replaces
/// [DummyRefiner] from Phase 2. Enqueues the downstream embed job on
/// success, same as the dummy did, so the rest of the pipeline doesn't
/// care which refiner ran.
class GemmaRefiner implements JobHandler {
  GemmaRefiner({
    required this.runner,
    required this.voiceLogs,
    required this.mentions,
    required this.queue,
  });

  final LlmRunner runner;
  final VoiceLogRepository voiceLogs;
  final EntityMentionRepository mentions;
  final JobQueue queue;

  final _log = Logger('gemma_refiner');

  @override
  JobType get type => JobType.refine;

  @override
  Future<Result<JobOutcome, AppError>> handle(JobContext ctx) async {
    final log = await voiceLogs.find(ctx.logId);
    if (log == null) {
      return const Ok(JobFailedPermanently('log not found'));
    }
    if (log.rawTranscript.trim().isEmpty) {
      await voiceLogs.markRefined(
        id: ctx.logId,
        cleanedText: log.rawTranscript,
      );
      await queue.enqueue(logId: ctx.logId, type: JobType.embed);
      return const Ok(JobSucceeded());
    }

    final loaded = await runner.load();
    switch (loaded) {
      case Ok():
        break;
      case Err(:final error):
        return Err(error);
    }

    // First pass.
    final firstRes = await runner.generate(recordLogPrompt(log.rawTranscript));
    String rawResponse;
    switch (firstRes) {
      case Ok(:final value):
        rawResponse = value;
      case Err(:final error):
        return Err(error);
    }

    var parsed = parseRecordLog(rawResponse);
    if (parsed == null) {
      _log.w('record_log parse failed — retrying with stricter prompt');
      final retry = await runner.generate(
        recordLogRetryPrompt(log.rawTranscript, rawResponse),
      );
      switch (retry) {
        case Ok(:final value):
          parsed = parseRecordLog(value);
        case Err(:final error):
          return Err(error);
      }
    }

    // Parse still failed — degrade gracefully and keep raw transcript.
    if (parsed == null) {
      _log.w('record_log retry also failed; persisting raw transcript');
      await voiceLogs.markRefined(
        id: ctx.logId,
        cleanedText: log.rawTranscript,
      );
      await queue.enqueue(logId: ctx.logId, type: JobType.embed);
      return const Ok(JobSucceeded());
    }

    final located = recoverOffsets(
      cleanedText: parsed.cleanedText,
      mentions: parsed.mentions,
    );

    final markRes = await voiceLogs.markRefined(
      id: ctx.logId,
      cleanedText: parsed.cleanedText,
    );
    switch (markRes) {
      case Ok():
        break;
      case Err(:final error):
        return Err(error);
    }

    final mentionRes = await mentions.replaceForLog(
      logId: ctx.logId,
      mentions: located,
    );
    switch (mentionRes) {
      case Ok():
        break;
      case Err(:final error):
        return Err(error);
    }

    await queue.enqueue(logId: ctx.logId, type: JobType.embed);
    return const Ok(JobSucceeded());
  }
}
