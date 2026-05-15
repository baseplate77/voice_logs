import 'dart:convert';

import '../../core/db/repositories/log_summary_repository.dart';

const int _kMaxBullets = 5;
const int _kMaxListItems = 8;
const int _kMaxOneLinerChars = 200;
const int _kMaxBulletChars = 240;
const int _kMaxItemChars = 160;
const int _kMaxMoodChars = 120;

const List<String> _oneLinerKeys = <String>[
  'one_liner',
  'oneLiner',
  'summary',
  'one_line',
  'headline',
];

const List<String> _dailyBulletsKeys = <String>[
  'what_happened',
  'whatHappened',
  'bullets',
  'highlights',
  'key_points',
];

const List<String> _dailyTopicsKeys = <String>[
  'people_mentioned',
  'peopleMentioned',
  'people',
  'people_projects',
  'peopleProjects',
];

const List<String> _dailyActionsKeys = <String>[
  'tasks_created',
  'tasksCreated',
  'tasks',
  'todos',
  'follow_ups',
  'followUps',
  'action_items',
];

const List<String> _dailyDecisionsKeys = <String>[
  'decisions',
  'decisions_made',
  'choices',
];

const List<String> _dailyMoodKeys = <String>[
  'mood_theme',
  'moodTheme',
  'mood',
  'theme',
];

const List<String> _weeklyBulletsKeys = <String>[
  'main_themes',
  'mainThemes',
  'themes',
  'bullets',
];

const List<String> _weeklyTopicsKeys = <String>[
  'project_progress',
  'projectProgress',
  'progress',
  'projects',
];

const List<String> _weeklyActionsKeys = <String>[
  'unfinished_tasks',
  'unfinishedTasks',
  'open_tasks',
  'todos',
  'tasks',
];

const List<String> _weeklyDecisionsKeys = <String>[
  'repeated_concerns',
  'repeatedConcerns',
  'concerns',
  'worries',
];

/// Parse the daily-digest response into a [DigestWrite]. Returns null when
/// the response cannot be parsed or has no usable one-liner; the caller is
/// expected to retry once and then accept that no row will be written
/// (mirrors how the per-log summary parser handles parse failure).
DigestWrite? parseDailyDigestResponse(String response) {
  final record = _decodeAndUnwrap(response);
  if (record == null) return null;

  final oneLiner = _sanitizeOneLiner(_firstString(record, _oneLinerKeys));
  if (oneLiner == null) return null;

  final bullets = _sanitizeBulletList(_firstList(record, _dailyBulletsKeys));
  final topics = _sanitizeShortList(_firstList(record, _dailyTopicsKeys));
  final actions = _sanitizeShortList(_firstList(record, _dailyActionsKeys));
  final decisions = _sanitizeShortList(_firstList(record, _dailyDecisionsKeys));
  final mood = _sanitizeMood(_firstString(record, _dailyMoodKeys));

  return DigestWrite(
    oneLiner: oneLiner,
    bullets: bullets,
    topics: topics,
    actions: actions,
    decisions: decisions,
    mood: mood,
  );
}

/// Parse the weekly-digest response into a [DigestWrite]. Returns null
/// under the same conditions as [parseDailyDigestResponse]. The `mood`
/// field is always null on the weekly path — the weekly schema doesn't
/// include a mood line.
DigestWrite? parseWeeklyDigestResponse(String response) {
  final record = _decodeAndUnwrap(response);
  if (record == null) return null;

  final oneLiner = _sanitizeOneLiner(_firstString(record, _oneLinerKeys));
  if (oneLiner == null) return null;

  final bullets = _sanitizeBulletList(_firstList(record, _weeklyBulletsKeys));
  final topics = _sanitizeShortList(_firstList(record, _weeklyTopicsKeys));
  final actions = _sanitizeShortList(_firstList(record, _weeklyActionsKeys));
  final decisions = _sanitizeShortList(
    _firstList(record, _weeklyDecisionsKeys),
  );

  return DigestWrite(
    oneLiner: oneLiner,
    bullets: bullets,
    topics: topics,
    actions: actions,
    decisions: decisions,
  );
}

Map<String, dynamic>? _decodeAndUnwrap(String response) {
  final json = _extractJson(response);
  if (json == null) return null;
  final Map<String, dynamic> initial;
  try {
    final decoded = jsonDecode(json);
    if (decoded is! Map) return null;
    initial = Map<String, dynamic>.from(decoded);
  } on FormatException {
    return null;
  }
  var record = initial;
  for (final wrapper in const <String>[
    'digest',
    'summary',
    'result',
    'output',
    'data',
    'arguments',
  ]) {
    final nested = record[wrapper];
    if (nested is Map) {
      record = Map<String, dynamic>.from(nested);
      break;
    }
  }
  return record;
}

String? _firstString(Map<String, dynamic> map, List<String> keys) {
  for (final key in keys) {
    final value = map[key];
    if (value is String && value.trim().isNotEmpty) return value;
  }
  return null;
}

List<dynamic>? _firstList(Map<String, dynamic> map, List<String> keys) {
  for (final key in keys) {
    final value = map[key];
    if (value is List) return value;
    if (value is String && value.trim().isNotEmpty) {
      return value
          .split(RegExp(r'[,;\n]'))
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList();
    }
  }
  return null;
}

String? _sanitizeOneLiner(String? raw) {
  if (raw == null) return null;
  var line = raw
      .replaceAll(RegExp(r'[\r\n]+'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  line = line.replaceAll(RegExp(r'''^["“”'\s]+|["“”'\s]+$'''), '').trim();
  if (line.isEmpty) return null;
  if (line.length > _kMaxOneLinerChars) {
    line = line.substring(0, _kMaxOneLinerChars).trimRight();
  }
  return line;
}

String? _sanitizeMood(String? raw) {
  if (raw == null) return null;
  var line = raw
      .replaceAll(RegExp(r'[\r\n]+'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  line = line.replaceAll(RegExp(r'''^["“”'\s]+|["“”'\s]+$'''), '').trim();
  if (line.isEmpty) return null;
  if (line.length > _kMaxMoodChars) {
    line = line.substring(0, _kMaxMoodChars).trimRight();
  }
  return line;
}

List<String> _sanitizeBulletList(List<dynamic>? raw) {
  if (raw == null) return const <String>[];
  final out = <String>[];
  final seen = <String>{};
  for (final item in raw) {
    final cleaned = _sanitizeBullet(item);
    if (cleaned == null) continue;
    final key = cleaned.toLowerCase();
    if (!seen.add(key)) continue;
    out.add(cleaned);
    if (out.length >= _kMaxBullets) break;
  }
  return List<String>.unmodifiable(out);
}

List<String> _sanitizeShortList(List<dynamic>? raw) {
  if (raw == null) return const <String>[];
  final out = <String>[];
  final seen = <String>{};
  for (final item in raw) {
    final cleaned = _sanitizeShortItem(item);
    if (cleaned == null) continue;
    final key = cleaned.toLowerCase();
    if (!seen.add(key)) continue;
    out.add(cleaned);
    if (out.length >= _kMaxListItems) break;
  }
  return List<String>.unmodifiable(out);
}

String? _sanitizeBullet(Object? raw) {
  final text = _stringValue(raw);
  if (text == null) return null;
  var cleaned = text
      .replaceAll(RegExp(r'[\r\n]+'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  cleaned = cleaned.replaceFirst(RegExp(r'^(?:[-*•]|\d+[\.\)])\s+'), '');
  cleaned = cleaned.trim();
  if (cleaned.isEmpty) return null;
  if (cleaned.length > _kMaxBulletChars) {
    cleaned = cleaned.substring(0, _kMaxBulletChars).trimRight();
  }
  return cleaned;
}

String? _sanitizeShortItem(Object? raw) {
  final text = _stringValue(raw);
  if (text == null) return null;
  var cleaned = text
      .replaceAll(RegExp(r'[\r\n]+'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  cleaned = cleaned.replaceFirst(RegExp(r'^(?:[-*•]|\d+[\.\)])\s+'), '');
  cleaned = cleaned.replaceAll(RegExp(r'''^["“”'\s]+|["“”'\s]+$'''), '');
  cleaned = cleaned.trim();
  if (cleaned.isEmpty) return null;
  if (cleaned.length > _kMaxItemChars) {
    cleaned = cleaned.substring(0, _kMaxItemChars).trimRight();
  }
  return cleaned;
}

String? _stringValue(Object? raw) {
  if (raw is String) return raw;
  if (raw is Map) {
    for (final key in const <String>['text', 'value', 'item', 'name']) {
      final v = raw[key];
      if (v is String && v.trim().isNotEmpty) return v;
    }
  }
  return null;
}

/// Permissive JSON extractor. Mirrors the walker used by the refine,
/// memory, and summarize parsers so this stage tolerates the same
/// code-fence and stray-prose patterns Gemma 3 1B occasionally emits.
String? _extractJson(String response) {
  final firstBrace = response.indexOf('{');
  if (firstBrace < 0) return null;
  var depth = 0;
  var inString = false;
  var escaped = false;
  for (var i = firstBrace; i < response.length; i++) {
    final c = response[i];
    if (escaped) {
      escaped = false;
      continue;
    }
    if (inString && c == r'\') {
      escaped = true;
      continue;
    }
    if (c == '"') {
      inString = !inString;
      continue;
    }
    if (inString) continue;
    if (c == '{') depth++;
    if (c == '}') {
      depth--;
      if (depth == 0) {
        return response.substring(firstBrace, i + 1);
      }
    }
  }
  return null;
}
