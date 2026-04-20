import 'dart:convert';

import '../../core/errors.dart';
import '../../core/logger.dart';
import '../../core/result.dart';
import '../../llm/llm_runner.dart';
import '../../llm/prompt_templates.dart';
import '../../store/models/voice_log_record.dart';
import '../../store/voice_log_repository.dart';
import 'daily_brief_job.dart';
import 'models/synthesis_kind.dart';
import 'models/weekly_themes.dart';

const PromptTemplate _weeklyThemesTemplate = PromptTemplate(
  name: 'weekly_themes',
  body: '''
You are VoxSynth, rolling up a full week of the user's voice notes
into recurring themes and stance contradictions. Re-runs on identical
inputs must produce identical outputs, so stick to the sources below.

Sources (each tagged `[Cn]`):
{{sources}}

Output ONLY a JSON object, no prose, no markdown fences, in this exact
shape:
  {
    "themes": [
      {
        "title": "…",
        "summary": "one-sentence description",
        "supporting_chunk_ids": [<int>, <int>, …]
      }
    ],
    "contradictions": [
      {
        "earlier_position": "…",
        "later_position": "…",
        "earlier_chunk_ids": [<int>, …],
        "later_chunk_ids": [<int>, …]
      }
    ]
  }

Rules:
- 3 to 5 themes. Each theme MUST have ≥2 supporting_chunk_ids drawn
  from the sources above. If fewer than 3 themes emerge, return what
  you have.
- Only include contradictions where the user clearly shifted stance
  within the week. Empty array is valid.
- If the week was empty, return {"themes":[],"contradictions":[]}.
''',
  requiredVariables: <String>['sources'],
);

/// Weekly themes + contradictions generator — runs Sunday 02:30 via
/// [BackgroundScheduler].
///
/// Mirrors [DailyBriefJob]'s shape: deterministic inputs
/// (`createdAt ASC, id ASC` via `chunksInRange`), temperature 0.2, a
/// single LLM call, graceful fallback on parse failure, one row
/// persisted to `syntheses`.
class WeeklyThemesJob {
  WeeklyThemesJob({
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

  /// Run for the 7-day window ending at the end of [weekEnding]'s
  /// day (defaults to "now"). Start is `end - 7 days` so the window
  /// is always exactly one week wide.
  Future<Result<WeeklyThemesJobOutput, AppError>> run({
    DateTime? weekEnding,
  }) async {
    final ref = weekEnding ?? _now();
    final end = DateTime(ref.year, ref.month, ref.day)
        .add(const Duration(days: 1))
        .subtract(const Duration(milliseconds: 1));
    final start = DateTime(ref.year, ref.month, ref.day)
        .subtract(const Duration(days: 6));

    final chunksR = await repository.chunksInRange(
      from: start,
      to: end,
    );
    if (chunksR.isErr) {
      return Err<WeeklyThemesJobOutput, AppError>(chunksR.errOrNull!);
    }
    final chunks = chunksR.okOrNull!;

    final WeeklyThemes themes;
    if (chunks.isEmpty) {
      themes = WeeklyThemes(
        weekStart: _fmtDay(start),
        themes: const <WeeklyTheme>[],
        contradictions: const <WeeklyContradiction>[],
      );
    } else {
      final prompt = _weeklyThemesTemplate.render(<String, String>{
        'sources': _formatChunks(chunks),
      });
      final response = await runner.generateSync(
        prompt,
        temperatureOverride: kBackgroundJobTemperature,
      );
      if (response.isErr) {
        return Err<WeeklyThemesJobOutput, AppError>(response.errOrNull!);
      }
      final parsed = _parseThemes(response.okOrNull!, _fmtDay(start));
      if (parsed == null) {
        _logger.warn(
          'WeeklyThemesJob: LLM output failed to parse; empty fallback',
        );
        themes = WeeklyThemes(
          weekStart: _fmtDay(start),
          themes: const <WeeklyTheme>[],
          contradictions: const <WeeklyContradiction>[],
        );
      } else {
        themes = parsed;
      }
    }

    final insertR = await repository.insertSynthesis(
      kind: kSynthesisKindWeeklyThemes,
      periodStart: start,
      periodEnd: end,
      payloadJson: jsonEncode(themes.toJson()),
      createdAt: _now(),
    );
    if (insertR.isErr) {
      return Err<WeeklyThemesJobOutput, AppError>(insertR.errOrNull!);
    }
    return Ok<WeeklyThemesJobOutput, AppError>(
      WeeklyThemesJobOutput(
        synthesisId: insertR.okOrNull!,
        themes: themes,
      ),
    );
  }

  static String _formatChunks(List<ChunkRecord> chunks) {
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

  static WeeklyThemes? _parseThemes(String raw, String weekStart) {
    final stripped = _stripCodeFences(raw);
    Object? decoded;
    try {
      decoded = jsonDecode(stripped);
    } on FormatException {
      return null;
    }
    if (decoded is! Map) return null;
    final themes = <WeeklyTheme>[];
    final themesRaw = decoded['themes'];
    if (themesRaw is List) {
      for (final item in themesRaw) {
        if (item is! Map) continue;
        final title = item['title'];
        final summary = item['summary'];
        if (title is! String || summary is! String) continue;
        final ids = _parseIntList(item['supporting_chunk_ids']);
        themes.add(
          WeeklyTheme(
            title: title,
            summary: summary,
            supportingChunkIds: ids,
          ),
        );
      }
    }
    final contradictions = <WeeklyContradiction>[];
    final contradictionsRaw = decoded['contradictions'];
    if (contradictionsRaw is List) {
      for (final item in contradictionsRaw) {
        if (item is! Map) continue;
        final earlier = item['earlier_position'];
        final later = item['later_position'];
        if (earlier is! String || later is! String) continue;
        contradictions.add(
          WeeklyContradiction(
            earlierPosition: earlier,
            laterPosition: later,
            earlierChunkIds: _parseIntList(item['earlier_chunk_ids']),
            laterChunkIds: _parseIntList(item['later_chunk_ids']),
          ),
        );
      }
    }
    return WeeklyThemes(
      weekStart: weekStart,
      themes: themes,
      contradictions: contradictions,
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
final class WeeklyThemesJobOutput {
  const WeeklyThemesJobOutput({
    required this.synthesisId,
    required this.themes,
  });

  final int synthesisId;
  final WeeklyThemes themes;
}
