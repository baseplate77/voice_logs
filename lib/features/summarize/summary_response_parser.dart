import 'dart:convert';

import '../../core/db/repositories/log_summary_repository.dart';

const int _kMaxBullets = 3;
const int _kMaxListItems = 8;
const int _kMaxOneLinerChars = 200;
const int _kMaxItemChars = 160;
const int _kMaxBulletChars = 240;

const List<String> _oneLinerKeys = <String>[
  'one_liner',
  'oneLiner',
  'summary',
  'one_line',
  'headline',
];

const List<String> _bulletsKeys = <String>['bullets', 'points', 'key_points'];

const List<String> _peopleProjectsKeys = <String>[
  'people_projects',
  'peopleProjects',
  'important_people_projects',
  'important_people',
  'people',
  'projects',
  'people_and_projects',
];

const List<String> _decisionsKeys = <String>[
  'decisions',
  'decisions_made',
  'choices',
];

const List<String> _followUpsKeys = <String>[
  'follow_ups',
  'followUps',
  'follow_up',
  'action_items',
  'actionItems',
  'todos',
  'next_steps',
];

/// Parse the summarize-stage response into a [LogSummaryWrite]. Returns null
/// when the response cannot be parsed or has no usable one-liner; the caller
/// is expected to retry once and then accept that the log will have no
/// summary row (mirrors how prompt suggestions handle parse failure).
LogSummaryWrite? parseSummaryResponse(String response) {
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

  // Some models nest the object under a single wrapper key.
  for (final wrapper in const <String>[
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

  final oneLiner = _sanitizeOneLiner(_firstString(record, _oneLinerKeys));
  if (oneLiner == null) return null;

  final bullets = _sanitizeBulletList(_firstList(record, _bulletsKeys));
  final peopleProjects = _sanitizeShortList(
    _firstList(record, _peopleProjectsKeys),
  );
  final decisions = _sanitizeShortList(_firstList(record, _decisionsKeys));
  final followUps = _sanitizeShortList(_firstList(record, _followUpsKeys));

  return LogSummaryWrite(
    oneLiner: oneLiner,
    bullets: bullets,
    peopleProjects: peopleProjects,
    decisions: decisions,
    followUps: followUps,
  );
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
      // Some small models occasionally emit a comma-separated string.
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
  // Strip leading list markers like "- ", "* ", "• ", "1) ", "1. ".
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

/// Permissive JSON extractor. Mirrors the walker used by the refine and
/// memory parsers so the summarize stage tolerates the same code-fence and
/// stray-prose patterns Gemma 3 1B occasionally emits.
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
