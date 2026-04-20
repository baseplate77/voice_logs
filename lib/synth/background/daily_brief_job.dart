import 'dart:convert';

import '../../core/errors.dart';
import '../../core/logger.dart';
import '../../core/result.dart';
import '../../llm/llm_runner.dart';
import '../../llm/prompt_templates.dart';
import '../../store/models/voice_log_record.dart';
import '../../store/voice_log_repository.dart';
import 'models/daily_brief.dart';
import 'models/synthesis_kind.dart';

/// Low temperature for every background job. Higher values would give
/// noticeably different briefs on re-run, which breaks the plan's
/// idempotency requirement (IMPLEMENTATION_PLAN §8, "All jobs
/// idempotent").
const double kBackgroundJobTemperature = 0.2;

const PromptTemplate _dailyBriefTemplate = PromptTemplate(
  name: 'daily_brief',
  body: '''
You are VoxSynth, summarising a single day of the user's voice notes
into a deterministic brief. The user will re-run this job; identical
inputs must yield identical outputs, so stay grounded in the sources
below and avoid speculation.

Sources (each tagged `[Cn]` — reference these ids in action items and
key moments):
{{sources}}

Output ONLY a JSON object, no prose, no markdown fences, in this exact
shape:
  {
    "summary": "one-paragraph overview of the day",
    "action_items": [
      {"text": "…", "source_chunk_ids": [<int>, …]}
    ],
    "key_moments": [
      {"description": "…", "source_chunk_ids": [<int>, …]}
    ]
  }

Rules:
- 3–5 key_moments when the day has material; fewer if it was quiet.
- action_items must be concrete TODOs ("send X", "review Y"). If the
  day held no TODOs, return an empty array.
- source_chunk_ids must reference actual chunk ids from the sources.
- If the day was empty or had no voice logs, return:
  {"summary":"No activity on this day.","action_items":[],"key_moments":[]}
''',
  requiredVariables: <String>['sources'],
);

/// Daily brief generator — runs overnight via [BackgroundScheduler].
///
/// Pipeline:
///   1. Fetch today's chunks via [VoiceLogRepository.chunksInRange].
///   2. Format into the prompt's Sources block (tagged `[Cn]`).
///   3. Generate JSON via Gemma at temperature 0.2 for idempotency.
///   4. Parse into [DailyBrief]; persist as a `SynthesisRow`.
///
/// Every failure is recoverable by retrying the job; partial progress
/// is never persisted. Returns the inserted row id on success.
class DailyBriefJob {
  DailyBriefJob({
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

  /// Run for the day containing [dayOf] (defaults to "now"). The
  /// period covered is `[00:00, 23:59:59.999]` local time — the
  /// user's reading of "today" on mobile.
  Future<Result<DailyBriefJobOutput, AppError>> run({
    DateTime? dayOf,
  }) async {
    final ref = dayOf ?? _now();
    final dayStart = DateTime(ref.year, ref.month, ref.day);
    final dayEnd = dayStart
        .add(const Duration(days: 1))
        .subtract(const Duration(milliseconds: 1));

    final chunksR = await repository.chunksInRange(
      from: dayStart,
      to: dayEnd,
    );
    if (chunksR.isErr) {
      return Err<DailyBriefJobOutput, AppError>(chunksR.errOrNull!);
    }
    final chunks = chunksR.okOrNull!;

    final DailyBrief brief;
    if (chunks.isEmpty) {
      // Short-circuit: avoid burning an LLM call on an empty day.
      brief = DailyBrief(
        date: _fmtDay(dayStart),
        summary: 'No activity on this day.',
        actionItems: const <DailyActionItem>[],
        keyMoments: const <DailyKeyMoment>[],
      );
    } else {
      final prompt = _dailyBriefTemplate.render(<String, String>{
        'sources': _formatChunks(chunks),
      });
      final response = await runner.generateSync(
        prompt,
        temperatureOverride: kBackgroundJobTemperature,
      );
      if (response.isErr) {
        return Err<DailyBriefJobOutput, AppError>(response.errOrNull!);
      }
      final parsed = _parseBrief(response.okOrNull!, _fmtDay(dayStart));
      if (parsed == null) {
        _logger.warn(
          'DailyBriefJob: LLM output failed to parse as JSON; '
          'falling back to empty brief',
        );
        brief = DailyBrief(
          date: _fmtDay(dayStart),
          summary: 'No brief could be generated for this day.',
          actionItems: const <DailyActionItem>[],
          keyMoments: const <DailyKeyMoment>[],
        );
      } else {
        brief = parsed;
      }
    }

    final insertR = await repository.insertSynthesis(
      kind: kSynthesisKindDailyBrief,
      periodStart: dayStart,
      periodEnd: dayEnd,
      payloadJson: jsonEncode(brief.toJson()),
      createdAt: _now(),
    );
    if (insertR.isErr) {
      return Err<DailyBriefJobOutput, AppError>(insertR.errOrNull!);
    }
    return Ok<DailyBriefJobOutput, AppError>(
      DailyBriefJobOutput(synthesisId: insertR.okOrNull!, brief: brief),
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

  /// Parse the LLM's JSON response. Returns null on any structural
  /// issue — caller falls back to a placeholder brief.
  static DailyBrief? _parseBrief(String raw, String date) {
    final stripped = _stripCodeFences(raw);
    Object? decoded;
    try {
      decoded = jsonDecode(stripped);
    } on FormatException {
      return null;
    }
    if (decoded is! Map) return null;
    final summary = decoded['summary'];
    if (summary is! String) return null;
    final actions = <DailyActionItem>[];
    final actionsRaw = decoded['action_items'];
    if (actionsRaw is List) {
      for (final item in actionsRaw) {
        if (item is! Map) continue;
        final text = item['text'];
        if (text is! String) continue;
        final ids = _parseIntList(item['source_chunk_ids']);
        actions.add(DailyActionItem(text: text, sourceChunkIds: ids));
      }
    }
    final moments = <DailyKeyMoment>[];
    final momentsRaw = decoded['key_moments'];
    if (momentsRaw is List) {
      for (final item in momentsRaw) {
        if (item is! Map) continue;
        final desc = item['description'];
        if (desc is! String) continue;
        final ids = _parseIntList(item['source_chunk_ids']);
        moments.add(
          DailyKeyMoment(description: desc, sourceChunkIds: ids),
        );
      }
    }
    return DailyBrief(
      date: date,
      summary: summary,
      actionItems: actions,
      keyMoments: moments,
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

/// Pairs the persisted [SynthesisRecord.id] with the parsed brief so
/// callers don't need to re-read from the db.
final class DailyBriefJobOutput {
  const DailyBriefJobOutput({
    required this.synthesisId,
    required this.brief,
  });

  final int synthesisId;
  final DailyBrief brief;
}
