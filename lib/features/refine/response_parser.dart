import 'dart:convert';

/// Parsed record_log output. Mentions are still unlocated — offsets are
/// recovered downstream via [recoverOffsets].
class ParsedRecordLog {
  const ParsedRecordLog({required this.cleanedText, required this.mentions});

  final String cleanedText;
  final List<({String text, String type})> mentions;
}

/// Canonical entity types the UI knows how to render. Anything the model
/// returns outside this set collapses to `OTHER`.
const List<String> _validEntityTypes = [
  'PERSON',
  'PLACE',
  'PROJECT',
  'DURATION',
  'TIME',
  'NUMBER',
  'OTHER',
];

/// Permissive JSON extractor — Gemma sometimes wraps the response in
/// markdown fences or leaves prose before the JSON. We look for the
/// first `{` and the matching closing `}` and try to parse that.
/// Returns `null` on failure so callers can trigger a stricter retry.
ParsedRecordLog? parseRecordLog(String response) {
  final json = _extractJson(response);
  if (json == null) return null;
  try {
    final decoded = jsonDecode(json);
    if (decoded is! Map<String, dynamic>) return null;
    final cleaned = decoded['cleaned_text'];
    if (cleaned is! String) return null;
    final rawMentions = decoded['entities'];
    final mentions = <({String text, String type})>[];
    if (rawMentions is List) {
      for (final m in rawMentions) {
        if (m is! Map<String, dynamic>) continue;
        final text = m['text'];
        final type = m['type'];
        if (text is! String || type is! String) continue;
        final upper = type.toUpperCase();
        final normalized = _validEntityTypes.contains(upper) ? upper : 'OTHER';
        mentions.add((text: text, type: normalized));
      }
    }
    return ParsedRecordLog(cleanedText: cleaned, mentions: mentions);
  } on FormatException {
    return null;
  }
}

String? _extractJson(String response) {
  final firstBrace = response.indexOf('{');
  if (firstBrace < 0) return null;
  // Walk braces to find the matching close. Strings are respected so a
  // `}` inside a JSON string doesn't end the document early.
  var depth = 0;
  var inString = false;
  var escaped = false;
  for (var i = firstBrace; i < response.length; i++) {
    final c = response[i];
    if (escaped) {
      escaped = false;
      continue;
    }
    if (c == r'\') {
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
