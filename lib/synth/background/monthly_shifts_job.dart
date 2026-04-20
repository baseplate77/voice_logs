import 'dart:convert';

import '../../core/errors.dart';
import '../../core/logger.dart';
import '../../core/result.dart';
import '../../llm/llm_runner.dart';
import '../../llm/prompt_templates.dart';
import '../../store/models/voice_log_record.dart';
import '../../store/voice_log_repository.dart';
import 'daily_brief_job.dart';
import 'models/monthly_shifts.dart';
import 'models/synthesis_kind.dart';

const PromptTemplate _monthlyShiftsTemplate = PromptTemplate(
  name: 'monthly_shifts',
  body: '''
You are VoxSynth, diffing this month against the previous 30 days.
The sources are split into two blocks: PRIOR (days -60 to -30 from
the run date) and CURRENT (days -30 to 0). Re-runs on identical
inputs must produce identical outputs, so keep every claim grounded
in the tagged chunks.

PRIOR sources:
{{prior_sources}}

CURRENT sources:
{{current_sources}}

Output ONLY a JSON object, no prose, no markdown fences, in this
shape:
  {
    "headline": "one-paragraph description of what's different",
    "shifts": [
      {
        "topic": "…",
        "prior_summary": "what you were saying then",
        "current_summary": "what you're saying now",
        "prior_chunk_ids": [<int>, …],
        "current_chunk_ids": [<int>, …]
      }
    ]
  }

Rules:
- Include shifts only where there's a concrete difference grounded in
  both PRIOR and CURRENT. If the month's indistinguishable from the
  prior month, return {"headline":"No notable shifts this month.","shifts":[]}.
- prior_chunk_ids and current_chunk_ids must come from the matching
  block.
''',
  requiredVariables: <String>['prior_sources', 'current_sources'],
);

/// Monthly shifts — what changed vs the prior 30 days. Runs on the
/// 1st of every month at 03:00 via [BackgroundScheduler].
///
/// Deliberately uses chunks only (no earlier syntheses) for the diff
/// so the reasoning happens in one LLM call over the raw ground
/// truth, not a cascade of summarisation lossiness. Earlier
/// syntheses stay available for the UI to surface alongside this
/// one, but the job doesn't chain through them.
class MonthlyShiftsJob {
  MonthlyShiftsJob({
    required this.repository,
    required this.runner,
    DateTime Function()? clock,
    AppLogger? logger,
  })  : _now = clock ?? DateTime.now,
        _logger = logger ?? AppLogger();

  final VoiceLogRepository repository;
  final LlmRunner runner;
  final DateTime Function() _now;
  final AppLogger _logger;

  /// Run for the month ending at [monthEnding] (defaults to "now").
  /// Compares `[monthEnding - 30d, monthEnding]` (CURRENT) against
  /// `[monthEnding - 60d, monthEnding - 30d]` (PRIOR).
  Future<Result<MonthlyShiftsJobOutput, AppError>> run({
    DateTime? monthEnding,
  }) async {
    final ref = monthEnding ?? _now();
    final end = DateTime(ref.year, ref.month, ref.day)
        .add(const Duration(days: 1))
        .subtract(const Duration(milliseconds: 1));
    final monthStart = DateTime(ref.year, ref.month, ref.day)
        .subtract(const Duration(days: 29));
    final priorEnd = monthStart.subtract(const Duration(milliseconds: 1));
    final priorStart = monthStart.subtract(const Duration(days: 30));

    final priorR = await repository.chunksInRange(
      from: priorStart,
      to: priorEnd,
    );
    if (priorR.isErr) {
      return Err<MonthlyShiftsJobOutput, AppError>(priorR.errOrNull!);
    }
    final currentR = await repository.chunksInRange(
      from: monthStart,
      to: end,
    );
    if (currentR.isErr) {
      return Err<MonthlyShiftsJobOutput, AppError>(currentR.errOrNull!);
    }
    final priorChunks = priorR.okOrNull!;
    final currentChunks = currentR.okOrNull!;

    final MonthlyShifts shifts;
    if (currentChunks.isEmpty && priorChunks.isEmpty) {
      shifts = MonthlyShifts(
        monthStart: _fmtDay(monthStart),
        headline: 'No notable shifts this month.',
        shifts: const <MonthlyShift>[],
      );
    } else {
      final prompt = _monthlyShiftsTemplate.render(<String, String>{
        'prior_sources': _formatChunks(priorChunks, emptyPlaceholder:
            '(no chunks in the prior 30 days)'),
        'current_sources': _formatChunks(currentChunks,
            emptyPlaceholder: '(no chunks in the current 30 days)'),
      });
      final response = await runner.generateSync(
        prompt,
        temperatureOverride: kBackgroundJobTemperature,
      );
      if (response.isErr) {
        return Err<MonthlyShiftsJobOutput, AppError>(response.errOrNull!);
      }
      final parsed =
          _parseShifts(response.okOrNull!, _fmtDay(monthStart));
      if (parsed == null) {
        _logger.warn(
          'MonthlyShiftsJob: LLM output failed to parse; empty fallback',
        );
        shifts = MonthlyShifts(
          monthStart: _fmtDay(monthStart),
          headline: 'No notable shifts this month.',
          shifts: const <MonthlyShift>[],
        );
      } else {
        shifts = parsed;
      }
    }

    final insertR = await repository.insertSynthesis(
      kind: kSynthesisKindMonthlyShifts,
      periodStart: monthStart,
      periodEnd: end,
      payloadJson: jsonEncode(shifts.toJson()),
      createdAt: _now(),
    );
    if (insertR.isErr) {
      return Err<MonthlyShiftsJobOutput, AppError>(insertR.errOrNull!);
    }
    return Ok<MonthlyShiftsJobOutput, AppError>(
      MonthlyShiftsJobOutput(
        synthesisId: insertR.okOrNull!,
        shifts: shifts,
      ),
    );
  }

  static String _formatChunks(
    List<ChunkRecord> chunks, {
    required String emptyPlaceholder,
  }) {
    if (chunks.isEmpty) return emptyPlaceholder;
    final buf = StringBuffer();
    for (var i = 0; i < chunks.length; i++) {
      if (i > 0) buf.write('\n\n');
      buf
        ..write('[C')
        ..write(chunks[i].id)
        ..write('] ')
        ..write(chunks[i].text);
    }
    return buf.toString();
  }

  static MonthlyShifts? _parseShifts(String raw, String monthStart) {
    final stripped = _stripCodeFences(raw);
    Object? decoded;
    try {
      decoded = jsonDecode(stripped);
    } on FormatException {
      return null;
    }
    if (decoded is! Map) return null;
    final headline = decoded['headline'];
    if (headline is! String) return null;
    final shifts = <MonthlyShift>[];
    final shiftsRaw = decoded['shifts'];
    if (shiftsRaw is List) {
      for (final item in shiftsRaw) {
        if (item is! Map) continue;
        final topic = item['topic'];
        final priorSummary = item['prior_summary'];
        final currentSummary = item['current_summary'];
        if (topic is! String ||
            priorSummary is! String ||
            currentSummary is! String) {
          continue;
        }
        shifts.add(
          MonthlyShift(
            topic: topic,
            priorSummary: priorSummary,
            currentSummary: currentSummary,
            priorChunkIds: _parseIntList(item['prior_chunk_ids']),
            currentChunkIds: _parseIntList(item['current_chunk_ids']),
          ),
        );
      }
    }
    return MonthlyShifts(
      monthStart: monthStart,
      headline: headline,
      shifts: shifts,
    );
  }

  static List<int> _parseIntList(Object? raw) {
    if (raw is! List) return const <int>[];
    final out = <int>[];
    for (final v in raw) {
      if (v is int) {
        out.add(v);
      } else if (v is num) {
        out.add(v.toInt());
      }
    }
    return out;
  }

  static String _stripCodeFences(String raw) {
    var s = raw.trim();
    if (s.startsWith('```')) {
      final firstNl = s.indexOf('\n');
      if (firstNl >= 0) s = s.substring(firstNl + 1);
      if (s.endsWith('```')) s = s.substring(0, s.length - 3);
    }
    return s.trim();
  }

  static String _fmtDay(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
}

/// Pairs the persisted synthesis id with the parsed payload.
final class MonthlyShiftsJobOutput {
  const MonthlyShiftsJobOutput({
    required this.synthesisId,
    required this.shifts,
  });

  final int synthesisId;
  final MonthlyShifts shifts;
}
