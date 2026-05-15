/// Prompt + parser + structured-fact model for the entity_summary
/// background job.
///
/// Two prompt variants share one response shape `{summary, facts}`:
///
///   * [entitySummaryFullPrompt] — rebuilds both summary and facts from
///     the latest log snippets. Used on first generation and every
///     [kFullRebuildEvery] mentions to fight incremental drift.
///   * [entitySummaryIncrementalPrompt] — feeds the existing facts plus
///     only the new log snippets and asks Gemma to merge. Cheaper and
///     keeps durable facts stable as new mentions land.
///
/// `facts` is an [EntityStructuredFacts] payload — a JSON blob persisted
/// in `entity_summaries.structured_facts`.
library;

import 'dart:convert';

/// Cap on durable facts kept per entity. Older facts are evicted before
/// new ones are appended so the prompt body stays bounded.
const int kMaxKeyFacts = 8;

/// Cap on recent themes kept per entity. Themes are short topic tags,
/// freshest first.
const int kMaxRecentThemes = 6;

/// How many new mentions accumulate (since the last full rebuild) before
/// we discard incremental drift and rebuild the summary from scratch.
const int kFullRebuildEvery = 10;

const int _kMaxBlurbChars = 280;
const int _kMinBlurbChars = 20;
const int _kMaxFactChars = 140;
const int _kMaxThemeChars = 40;

/// Durable per-entity background built up over many mentions. Persisted
/// as a JSON blob in `entity_summaries.structured_facts`.
class EntityStructuredFacts {
  const EntityStructuredFacts({
    required this.what,
    required this.keyFacts,
    required this.recentThemes,
    this.relationship,
    this.status,
    this.lastMergedLogId,
    this.lastFullRebuildAt,
    this.lastFullRebuildMentionCount,
  });

  /// Brief noun phrase: who/what this entity is from the user's POV.
  /// Examples: "engineering manager you work with at Google",
  /// "neighborhood cafe you visit on weekends".
  final String what;

  /// Durable facts the user mentioned over time. Capped at
  /// [kMaxKeyFacts]; oldest are evicted on overflow.
  final List<String> keyFacts;

  /// Short topic tags from recent mentions (e.g. "sprint planning").
  /// Capped at [kMaxRecentThemes].
  final List<String> recentThemes;

  /// PERSON only — how this person relates to the user (colleague,
  /// partner, friend, …). Null for non-PERSON entities.
  final String? relationship;

  /// PROJECT only — current status / phase. Null for non-PROJECT.
  final String? status;

  /// Newest voice-log id whose snippets have been merged into the facts.
  /// Drives the incremental "logs since" lookup in the job.
  final String? lastMergedLogId;

  /// Unix ms of the last full rebuild. Used with
  /// [lastFullRebuildMentionCount] to decide when to do the next one.
  final int? lastFullRebuildAt;

  /// Mention count snapshot at the last full rebuild. The job triggers a
  /// fresh rebuild when current mention count exceeds this by
  /// [kFullRebuildEvery].
  final int? lastFullRebuildMentionCount;

  static const empty = EntityStructuredFacts(
    what: '',
    keyFacts: <String>[],
    recentThemes: <String>[],
  );

  bool get isEmpty =>
      what.isEmpty &&
      keyFacts.isEmpty &&
      recentThemes.isEmpty &&
      (relationship?.isEmpty ?? true) &&
      (status?.isEmpty ?? true);

  EntityStructuredFacts copyWith({
    String? what,
    List<String>? keyFacts,
    List<String>? recentThemes,
    String? relationship,
    String? status,
    String? lastMergedLogId,
    int? lastFullRebuildAt,
    int? lastFullRebuildMentionCount,
  }) {
    return EntityStructuredFacts(
      what: what ?? this.what,
      keyFacts: keyFacts ?? this.keyFacts,
      recentThemes: recentThemes ?? this.recentThemes,
      relationship: relationship ?? this.relationship,
      status: status ?? this.status,
      lastMergedLogId: lastMergedLogId ?? this.lastMergedLogId,
      lastFullRebuildAt: lastFullRebuildAt ?? this.lastFullRebuildAt,
      lastFullRebuildMentionCount:
          lastFullRebuildMentionCount ?? this.lastFullRebuildMentionCount,
    );
  }

  Map<String, Object?> toJson() {
    return {
      'what': what,
      'key_facts': keyFacts,
      'recent_themes': recentThemes,
      if (relationship != null) 'relationship': relationship,
      if (status != null) 'status': status,
      if (lastMergedLogId != null) 'last_merged_log_id': lastMergedLogId,
      if (lastFullRebuildAt != null) 'last_full_rebuild_at': lastFullRebuildAt,
      if (lastFullRebuildMentionCount != null)
        'last_full_rebuild_mention_count': lastFullRebuildMentionCount,
    };
  }

  factory EntityStructuredFacts.fromJson(Map<String, Object?> json) {
    return EntityStructuredFacts(
      what: _stringOr(json['what'], ''),
      keyFacts: _stringList(json['key_facts'], _kMaxFactChars, kMaxKeyFacts),
      recentThemes: _stringList(
        json['recent_themes'],
        _kMaxThemeChars,
        kMaxRecentThemes,
      ),
      relationship: _nullableString(json['relationship']),
      status: _nullableString(json['status']),
      lastMergedLogId: _nullableString(json['last_merged_log_id']),
      lastFullRebuildAt: _nullableInt(json['last_full_rebuild_at']),
      lastFullRebuildMentionCount: _nullableInt(
        json['last_full_rebuild_mention_count'],
      ),
    );
  }

  static String? encode(EntityStructuredFacts? facts) =>
      facts == null ? null : jsonEncode(facts.toJson());

  static EntityStructuredFacts? decode(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, Object?>) {
        return EntityStructuredFacts.fromJson(decoded);
      }
    } on Object {
      // Fall through; corrupt JSON is treated as missing facts so the
      // job will rebuild from scratch on the next run.
    }
    return null;
  }
}

/// Context passed to the prompt builder.
class EntitySummaryPromptInput {
  const EntitySummaryPromptInput({
    required this.displayName,
    required this.type,
    required this.mentionCount,
    required this.recentLogTitles,
    required this.recentLogSnippets,
  });

  final String displayName;

  /// Canonical type ("PERSON", "PLACE", "PROJECT", "OBJECT", "OTHER", …).
  final String type;

  /// Current mention count across all logs.
  final int mentionCount;

  /// Most-recent log titles that mention this entity, freshest first.
  final List<String> recentLogTitles;

  /// Short snippets (~600 chars total) of cleaned log text where this
  /// entity appears, freshest first.
  final List<String> recentLogSnippets;
}

/// Combined response shape returned by both prompt variants.
class EntitySummaryGeneration {
  const EntitySummaryGeneration({required this.summary, required this.facts});

  final String summary;
  final EntityStructuredFacts facts;
}

/// Full-rebuild prompt. Used on first generation and every
/// [kFullRebuildEvery] mentions. Asks the LLM to derive both the
/// rendered summary and the structured facts from the recent snippets.
String entitySummaryFullPrompt(EntitySummaryPromptInput input) {
  final lens = _lensForType(input.type);
  final titles = input.recentLogTitles
      .where((t) => t.trim().isNotEmpty)
      .take(6)
      .map((t) => '- $t')
      .join('\n');
  final snippets = input.recentLogSnippets
      .where((s) => s.trim().isNotEmpty)
      .take(4)
      .map((s) => '> ${s.trim()}')
      .join('\n');
  final factsHint = _factsHintForType(input.type);

  return '''
You are VoxSynth, building a background dossier for a $lens in the user's local voice journal.
Read the snippets below and produce a 2-3 sentence summary about "${input.displayName}" plus a structured facts object.

Output exactly one minified JSON object and nothing else, with this shape:
{"summary":"...","facts":{"what":"...","key_facts":["..."],"recent_themes":["..."]$factsHint}}

Rules:
- "summary" is 2-3 sentences in second person ("you discussed…", "your work on…").
- "what" is a short noun phrase (≤ 12 words) describing who/what this $lens is from the user's POV.
- "key_facts" is up to $kMaxKeyFacts durable, specific facts the user actually said. Skip speculation.
- "recent_themes" is up to $kMaxRecentThemes short topic tags (1-4 words each), freshest first.
- Do not invent facts. Use only what's in the snippets and titles below.
- No markdown, no headings, no citations, no meta-text.
- Stop after the closing brace.

Recent log titles:
$titles

Recent log snippets:
$snippets
''';
}

/// Incremental merge prompt. Feeds the existing structured facts and the
/// new log snippet(s) and asks the LLM to update both the summary and the
/// facts in place.
String entitySummaryIncrementalPrompt({
  required EntitySummaryPromptInput input,
  required EntityStructuredFacts currentFacts,
  required List<String> newLogTitles,
  required List<String> newLogSnippets,
}) {
  final lens = _lensForType(input.type);
  final factsJson = jsonEncode(currentFacts.toJson());
  final titles = newLogTitles
      .where((t) => t.trim().isNotEmpty)
      .take(4)
      .map((t) => '- $t')
      .join('\n');
  final snippets = newLogSnippets
      .where((s) => s.trim().isNotEmpty)
      .take(3)
      .map((s) => '> ${s.trim()}')
      .join('\n');
  final factsHint = _factsHintForType(input.type);

  return '''
You are VoxSynth, updating an existing background dossier for a $lens in the user's local voice journal.
Merge the NEW log mentions below into the EXISTING facts about "${input.displayName}", then rewrite the 2-3 sentence summary.

EXISTING facts (JSON):
$factsJson

NEW log titles:
$titles

NEW log snippets:
$snippets

Output exactly one minified JSON object and nothing else:
{"summary":"...","facts":{"what":"...","key_facts":["..."],"recent_themes":["..."]$factsHint}}

Merge rules:
- Keep "what" stable unless the new mentions clearly contradict it.
- Append new durable facts; drop the oldest if "key_facts" exceeds $kMaxKeyFacts.
- Refresh "recent_themes" from the new snippets; drop the oldest if it exceeds $kMaxRecentThemes.
- "summary" is 2-3 sentences in second person, reflecting the merged facts (not just the new mention).
- Do not invent facts. Do not drop existing facts that are still consistent.
- No markdown, no headings, no citations, no meta-text.
- Stop after the closing brace.
''';
}

/// Stricter retry prompt used when the first response failed to parse.
String entitySummaryRetryPrompt({
  required EntitySummaryPromptInput input,
  required String previousResponse,
}) {
  return '''
Your previous response was invalid. Return exactly one minified JSON object
with "summary" and "facts" keys and no markdown or prose:
{"summary":"2-3 sentence narrative","facts":{"what":"...","key_facts":[],"recent_themes":[]}}

Entity: "${input.displayName}"

Invalid previous response:
$previousResponse
''';
}

/// Parse a `{summary, facts}` envelope into [EntitySummaryGeneration].
/// Returns null when the response is unusable so the handler can retry
/// once and then fall back to a deterministic blurb.
EntitySummaryGeneration? parseEntitySummaryGeneration(String response) {
  final json = _extractJson(response);
  if (json == null) return null;
  try {
    final decoded = jsonDecode(json);
    if (decoded is! Map<String, Object?>) return null;
    final summary = _sanitizeSummary(
      _firstStringField(decoded, const ['summary', 'text', 'blurb', 'about']),
    );
    if (summary == null) return null;
    final factsRaw = decoded['facts'];
    final facts = factsRaw is Map<String, Object?>
        ? EntityStructuredFacts.fromJson(factsRaw)
        : EntityStructuredFacts.empty;
    return EntitySummaryGeneration(summary: summary, facts: facts);
  } on Object {
    final loose = _looseStringField(json, const [
      'summary',
      'text',
      'blurb',
      'about',
    ]);
    final summary = _sanitizeSummary(loose);
    if (summary == null) return null;
    return EntitySummaryGeneration(
      summary: summary,
      facts: EntityStructuredFacts.empty,
    );
  }
}

/// Legacy parser kept for the older summary-only response shape. Some
/// callers and tests still expect this signature; under the hood it
/// reuses the combined parser.
String? parseEntitySummaryResponse(String response) {
  return parseEntitySummaryGeneration(response)?.summary;
}

/// Deterministic fallback used when Gemma fails or returns nothing
/// usable. Always renders something informative — "Mentioned in N logs"
/// with the top titles inline — so the entity page never shows empty.
String synthesizeFallbackEntitySummary(EntitySummaryPromptInput input) {
  final titles = input.recentLogTitles
      .where((t) => t.trim().isNotEmpty)
      .take(3)
      .map((t) => '"${t.trim()}"')
      .toList(growable: false);
  final lensNoun = _lensForType(input.type);
  if (titles.isEmpty) {
    return 'Mentioned in ${input.mentionCount} log${input.mentionCount == 1 ? '' : 's'} '
        'as a $lensNoun.';
  }
  return 'Mentioned in ${input.mentionCount} log${input.mentionCount == 1 ? '' : 's'}, '
      'most recently in ${titles.join(', ')}.';
}

String _lensForType(String type) {
  switch (type.toUpperCase()) {
    case 'PERSON':
      return 'person';
    case 'PLACE':
      return 'place';
    case 'PROJECT':
      return 'project';
    case 'OBJECT':
      return 'object';
    default:
      return 'topic';
  }
}

/// Per-type extra fields injected into the JSON shape hint so the LLM
/// emits `relationship` for PERSON entities and `status` for PROJECT
/// entities without us renaming the schema for the others.
String _factsHintForType(String type) {
  switch (type.toUpperCase()) {
    case 'PERSON':
      return ',"relationship":"…"';
    case 'PROJECT':
      return ',"status":"…"';
    default:
      return '';
  }
}

String? _sanitizeSummary(String? raw) {
  if (raw == null) return null;
  var text = raw
      .replaceAll(RegExp(r'[\r\n]+'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  text = text.replaceAll(RegExp(r'^["“”\s]+|["“”\s]+$'), '');
  if (text.length < _kMinBlurbChars) return null;
  if (text.length > _kMaxBlurbChars) {
    text = text.substring(0, _kMaxBlurbChars).trimRight();
    text = text.replaceAll(RegExp(r'[,;:.\s]+$'), '');
    if (!text.endsWith('.')) text = '$text…';
  }
  return text;
}

String? _extractJson(String response) {
  final fenced = RegExp(
    r'```(?:json)?\s*(\{[\s\S]*?\})\s*```',
  ).firstMatch(response);
  if (fenced != null) return fenced.group(1);
  final braceStart = response.indexOf('{');
  if (braceStart < 0) return null;
  final braceEnd = response.lastIndexOf('}');
  if (braceEnd <= braceStart) return null;
  return response.substring(braceStart, braceEnd + 1);
}

String? _firstStringField(Map<String, Object?> map, List<String> keys) {
  for (final key in keys) {
    final value = map[key];
    if (value is String && value.trim().isNotEmpty) return value;
  }
  return null;
}

String? _looseStringField(String source, List<String> keys) {
  for (final key in keys) {
    final match = RegExp(
      '"${RegExp.escape(key)}"\\s*:\\s*"([^"]*)"',
    ).firstMatch(source);
    if (match != null) return match.group(1);
  }
  return null;
}

String _stringOr(Object? value, String fallback) {
  if (value is String) return value.trim();
  return fallback;
}

String? _nullableString(Object? value) {
  if (value is String) {
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
  return null;
}

int? _nullableInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value);
  return null;
}

List<String> _stringList(Object? value, int maxCharsEach, int maxItems) {
  if (value is! List) return const <String>[];
  final out = <String>[];
  for (final item in value) {
    if (item is! String) continue;
    var trimmed = item.trim();
    if (trimmed.isEmpty) continue;
    if (trimmed.length > maxCharsEach) {
      trimmed = trimmed.substring(0, maxCharsEach).trimRight();
    }
    out.add(trimmed);
    if (out.length >= maxItems) break;
  }
  return List.unmodifiable(out);
}

/// Backwards-compatible alias kept until callers move to the full prompt.
/// The combined-shape prompt is the new default for both first generation
/// and every full rebuild — incremental updates use a different prompt.
String entitySummaryPrompt(EntitySummaryPromptInput input) =>
    entitySummaryFullPrompt(input);
