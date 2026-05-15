import '../../core/app_error.dart';
import '../../core/db/job_state.dart';
import '../../core/db/repositories/log_summary_repository.dart';
import '../../core/db/repositories/voice_log_repository.dart';
import '../../core/logger.dart';
import '../../core/result.dart';
import '../../core/worker/job_handler.dart';
import '../refine/llm_runner.dart';
import 'summary_prompt.dart';
import 'summary_response_parser.dart';

/// Worker handler for the per-log summarize stage.
///
/// Runs after embed. Pulls the cleaned transcript from voice_logs, asks the
/// LLM for a structured summary, and writes the result via
/// [LogSummaryRepository]. One stricter parse-retry is allowed; if the
/// retry also fails, the job completes successfully with no row so the rest
/// of the pipeline isn't blocked by a flaky summary.
class SummarizeRunner implements JobHandler {
  SummarizeRunner({
    required this.runner,
    required this.voiceLogs,
    required this.summaries,
    this.modelVersion,
  });

  final LlmRunner runner;
  final VoiceLogRepository voiceLogs;
  final LogSummaryRepository summaries;

  /// Tag stamped on each persisted summary row so we can later filter by
  /// model when re-running summaries. Currently informational only.
  final String? modelVersion;

  final _log = Logger('summarize_runner');

  @override
  JobType get type => JobType.summarize;

  @override
  Future<Result<JobOutcome, AppError>> handle(JobContext ctx) async {
    final total = Stopwatch()..start();
    _log.i(
      'Summarize start job=${ctx.jobId} log=${ctx.logId} '
      'attempt=${ctx.attempts}',
    );

    final log = await voiceLogs.find(ctx.logId);
    if (log == null) {
      _log.w('Summarize aborted: log not found after ${total.elapsed}');
      return const Ok(JobFailedPermanently('log not found'));
    }

    final cleanedText = (log.cleanedText ?? log.rawTranscript).trim();
    if (cleanedText.isEmpty) {
      _log.i('Summarize skipped: empty transcript');
      return const Ok(JobSucceeded());
    }

    final loaded = await runner.load();
    switch (loaded) {
      case Ok():
        break;
      case Err(:final error):
        _log.w('Summarize failed during LLM load', error: error);
        return Err(error);
    }

    final first = await runner.generate(
      summarizeLogPrompt(cleanedText),
      temperature: kSummarizeTemperature,
    );
    String rawResponse;
    switch (first) {
      case Ok(:final value):
        rawResponse = value;
        _log.i('Summarize response chars=${value.length}');
      case Err(:final error):
        _log.w('Summarize failed during LLM generation', error: error);
        return Err(error);
    }

    var parsed = parseSummaryResponse(rawResponse);
    if (parsed == null) {
      _log.w('Summarize parse failed; retrying with stricter prompt');
      final retry = await runner.generate(
        summarizeLogRetryPrompt(cleanedText, rawResponse),
        temperature: kSummarizeTemperature,
      );
      switch (retry) {
        case Ok(:final value):
          parsed = parseSummaryResponse(value);
        case Err(:final error):
          _log.w(
            'Summarize retry generation failed; skipping summary',
            error: error,
          );
          return const Ok(JobSucceeded());
      }
    }

    if (parsed == null) {
      _log.w('Summarize retry parse failed; skipping summary for log');
      return const Ok(JobSucceeded());
    }

    final upsert = await summaries.upsert(
      logId: ctx.logId,
      write: parsed,
      modelVersion: modelVersion,
    );
    switch (upsert) {
      case Ok():
        _log.i('Summarize complete in ${total.elapsed}');
        return const Ok(JobSucceeded());
      case Err(:final error):
        _log.w('Summarize failed while saving summary', error: error);
        return Err(error);
    }
  }
}
