import '../../core/app_error.dart';
import '../../core/db/job_state.dart';
import '../../core/db/repositories/log_summary_repository.dart';
import '../../core/db/repositories/voice_log_repository.dart';
import '../../core/logger.dart';
import '../../core/result.dart';
import '../../core/worker/job_handler.dart';
import '../../core/worker/job_queue.dart';
import '../refine/llm_runner.dart';
import 'digest_prompt.dart';
import 'digest_response_parser.dart';

/// Maximum number of logs fed into a single digest prompt. Above this we
/// drop the oldest entries to keep Gemma 3 1B inside its prompt budget.
const int kDigestMaxLogs = 40;

/// Maximum total characters of log body text we'll feed to the prompt.
const int kDigestBodyCharBudget = 12000;

/// Worker handler for [JobType.digest] — cross-log daily / weekly digests.
///
/// **Polymorphic queue id.** [JobContext.logId] carries the digest target id
/// (`daily:<yyyy-MM-dd>` or `weekly:<yyyy-MM-dd>`), not a voice-log id. The
/// rest of the pipeline still treats it as a log id, so we keep this
/// asymmetry localized to this handler — matching the pattern used by
/// `entity_summary_job.dart`.
class DigestRunner implements JobHandler {
  DigestRunner({
    required this.runner,
    required this.voiceLogs,
    required this.summaries,
  });

  final LlmRunner runner;
  final VoiceLogRepository voiceLogs;
  final LogSummaryRepository summaries;

  final _log = Logger('digest_runner');

  @override
  JobType get type => JobType.digest;

  @override
  Future<Result<JobOutcome, AppError>> handle(JobContext ctx) async {
    final total = Stopwatch()..start();
    final target = DigestTarget.tryParse(ctx.logId);
    if (target == null) {
      _log.w('Digest aborted: unparseable target ${ctx.logId}');
      return Ok(JobFailedPermanently('bad digest target: ${ctx.logId}'));
    }
    _log.i(
      'Digest start job=${ctx.jobId} target=${target.wire} '
      'attempt=${ctx.attempts}',
    );

    final window = target.window();
    final logs = await voiceLogs.findInWindow(
      start: window.start,
      end: window.end,
    );
    final inputs = _shapeLogsForPrompt(logs);
    if (inputs.isEmpty) {
      _log.i('Digest skipped: no logs in window ${target.wire}');
      return const Ok(JobSucceeded());
    }

    final loaded = await runner.load();
    switch (loaded) {
      case Ok():
        break;
      case Err(:final error):
        _log.w('Digest failed during LLM load', error: error);
        return Err(error);
    }

    final firstPrompt = _buildPrompt(target, inputs);
    final first = await runner.generate(
      firstPrompt,
      temperature: kDigestTemperature,
    );
    String rawResponse;
    switch (first) {
      case Ok(:final value):
        rawResponse = value;
        _log.i('Digest response chars=${value.length}');
      case Err(:final error):
        _log.w('Digest failed during LLM generation', error: error);
        return Err(error);
    }

    var parsed = _parse(target.kind, rawResponse);
    if (parsed == null) {
      _log.w('Digest parse failed; retrying with stricter prompt');
      final retry = await runner.generate(
        _buildRetryPrompt(target, inputs, rawResponse),
        temperature: kDigestTemperature,
      );
      switch (retry) {
        case Ok(:final value):
          parsed = _parse(target.kind, value);
        case Err(:final error):
          _log.w('Digest retry generation failed; skipping', error: error);
          return const Ok(JobSucceeded());
      }
    }

    if (parsed == null) {
      _log.w('Digest retry parse failed; skipping ${target.wire}');
      return const Ok(JobSucceeded());
    }

    final upsert = await summaries.upsertDigest(
      kind: target.kind,
      windowKey: target.windowKey,
      write: parsed,
    );
    switch (upsert) {
      case Ok():
        _log.i('Digest complete in ${total.elapsed}');
        return const Ok(JobSucceeded());
      case Err(:final error):
        _log.w('Digest failed while saving row', error: error);
        return Err(error);
    }
  }

  List<DigestLogInput> _shapeLogsForPrompt(List<VoiceLogView> logs) {
    final shaped = <DigestLogInput>[];
    // We feed newest-first so the budget always keeps the most recent
    // moments of the day/week; the rendered list is reversed at the end
    // so the prompt still reads oldest-first.
    final ordered = logs.reversed.toList(growable: false);
    var totalChars = 0;
    for (final log in ordered) {
      final body = (log.cleanedText?.trim().isNotEmpty ?? false)
          ? log.cleanedText!.trim()
          : log.rawTranscript.trim();
      if (body.isEmpty) continue;

      final remaining = kDigestBodyCharBudget - totalChars;
      if (remaining <= 120) break;
      final slice = body.length > remaining
          ? '${body.substring(0, remaining - 1)}…'
          : body;
      shaped.add(
        DigestLogInput(
          createdAt: log.createdAt,
          title: log.title ?? '',
          body: slice,
        ),
      );
      totalChars += slice.length;
      if (shaped.length >= kDigestMaxLogs) break;
    }
    return shaped.reversed.toList(growable: false);
  }

  String _buildPrompt(DigestTarget target, List<DigestLogInput> logs) {
    switch (target.kind) {
      case DigestKind.daily:
        return dailyDigestPrompt(dateLabel: target.label, logs: logs);
      case DigestKind.weekly:
        return weeklyDigestPrompt(windowLabel: target.label, logs: logs);
    }
  }

  String _buildRetryPrompt(
    DigestTarget target,
    List<DigestLogInput> logs,
    String previous,
  ) {
    switch (target.kind) {
      case DigestKind.daily:
        return dailyDigestRetryPrompt(
          dateLabel: target.label,
          logs: logs,
          previousResponse: previous,
        );
      case DigestKind.weekly:
        return weeklyDigestRetryPrompt(
          windowLabel: target.label,
          logs: logs,
          previousResponse: previous,
        );
    }
  }

  DigestWrite? _parse(DigestKind kind, String response) {
    switch (kind) {
      case DigestKind.daily:
        return parseDailyDigestResponse(response);
      case DigestKind.weekly:
        return parseWeeklyDigestResponse(response);
    }
  }
}

/// Half-open `[start, end)` time range, in the local timezone.
class DigestWindow {
  const DigestWindow({required this.start, required this.end});

  final DateTime start;
  final DateTime end;
}

/// Parsed digest target. Encapsulates the kind, the canonical window-key
/// string (used for `summaries.source_id`), and the time range to query.
class DigestTarget {
  const DigestTarget({
    required this.kind,
    required this.windowKey,
    required this.label,
  });

  final DigestKind kind;

  /// `yyyy-MM-dd` — for daily, the day itself; for weekly, the start of
  /// the 7-day window.
  final String windowKey;

  /// Human-readable label rendered into prompts.
  final String label;

  /// Wire id stored on the job row (also used as `summaries.id`).
  String get wire => '${kind.wire}:$windowKey';

  /// Local-time window this target covers. Daily is exactly the local
  /// calendar day; weekly is the 7 days `[start, start + 7)`.
  DigestWindow window() {
    final anchor = _parseKey(windowKey);
    switch (kind) {
      case DigestKind.daily:
        final start = DateTime(anchor.year, anchor.month, anchor.day);
        final end = start.add(const Duration(days: 1));
        return DigestWindow(start: start, end: end);
      case DigestKind.weekly:
        final start = DateTime(anchor.year, anchor.month, anchor.day);
        final end = start.add(const Duration(days: 7));
        return DigestWindow(start: start, end: end);
    }
  }

  /// Canonical target for "today" in the user's local timezone.
  static DigestTarget today({DateTime? now}) {
    final n = now ?? DateTime.now();
    final day = DateTime(n.year, n.month, n.day);
    return DigestTarget(
      kind: DigestKind.daily,
      windowKey: _formatDate(day),
      label: _formatDate(day),
    );
  }

  /// Canonical target for the 7-day window ending on the given local
  /// day (inclusive). Anchor = `endDay - 6 days`.
  static DigestTarget weekEndingOn({DateTime? endDay}) {
    final ref = endDay ?? DateTime.now();
    final endDayLocal = DateTime(ref.year, ref.month, ref.day);
    final start = endDayLocal.subtract(const Duration(days: 6));
    return DigestTarget(
      kind: DigestKind.weekly,
      windowKey: _formatDate(start),
      label: '${_formatDate(start)} to ${_formatDate(endDayLocal)}',
    );
  }

  /// Parse a wire id like `daily:2026-05-15` or `weekly:2026-05-09`.
  /// Returns null when the prefix is unknown or the date is malformed.
  static DigestTarget? tryParse(String wire) {
    final separator = wire.indexOf(':');
    if (separator <= 0 || separator == wire.length - 1) return null;
    final prefix = wire.substring(0, separator);
    final dateStr = wire.substring(separator + 1);
    DigestKind kind;
    switch (prefix) {
      case 'daily':
        kind = DigestKind.daily;
      case 'weekly':
        kind = DigestKind.weekly;
      default:
        return null;
    }
    final date = _tryParseKey(dateStr);
    if (date == null) return null;
    final base = DigestTarget(
      kind: kind,
      windowKey: _formatDate(date),
      label: '',
    );
    final label = kind == DigestKind.daily
        ? base.windowKey
        : '${base.windowKey} to ${_formatDate(date.add(const Duration(days: 6)))}';
    return DigestTarget(kind: kind, windowKey: base.windowKey, label: label);
  }

  static DateTime _parseKey(String key) {
    final parsed = _tryParseKey(key);
    if (parsed == null) {
      throw FormatException('Bad digest window key: $key');
    }
    return parsed;
  }

  static DateTime? _tryParseKey(String key) {
    final parts = key.split('-');
    if (parts.length != 3) return null;
    final year = int.tryParse(parts[0]);
    final month = int.tryParse(parts[1]);
    final day = int.tryParse(parts[2]);
    if (year == null || month == null || day == null) return null;
    if (month < 1 || month > 12 || day < 1 || day > 31) return null;
    return DateTime(year, month, day);
  }

  static String _formatDate(DateTime d) {
    final y = d.year.toString().padLeft(4, '0');
    final m = d.month.toString().padLeft(2, '0');
    final day = d.day.toString().padLeft(2, '0');
    return '$y-$m-$day';
  }
}

/// Enqueue a digest job for [target]. Returns the queued job id. Idempotent
/// for active work — see [JobQueue.enqueue] semantics. Re-running a digest
/// when a row already exists replaces it in place because the runner upserts
/// on `summaries.id = <kind>:<windowKey>`.
Future<String> enqueueDigest({
  required JobQueue queue,
  required DigestTarget target,
}) async {
  return queue.enqueue(logId: target.wire, type: JobType.digest);
}
