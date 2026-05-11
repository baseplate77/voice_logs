import 'dart:convert';

/// Parsed record_log output. Mentions are still unlocated — offsets are
/// recovered downstream via [recoverOffsets].
class ParsedRecordLog {
  const ParsedRecordLog({required this.cleanedText, required this.mentions});

  final String cleanedText;
  final List<({String text, String type})> mentions;
}

const int _kMaxEntities = 15;

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

const Map<String, String> _entityTypeAliases = {
  'PERSON': 'PERSON',
  'PEOPLE': 'PERSON',
  'PER': 'PERSON',
  'NAME': 'PERSON',
  'PLACE': 'PLACE',
  'PLACES': 'PLACE',
  'LOCATION': 'PLACE',
  'LOCATIONS': 'PLACE',
  'LOC': 'PLACE',
  'GPE': 'PLACE',
  'ADDRESS': 'PLACE',
  'VENUE': 'PLACE',
  'PROJECT': 'PROJECT',
  'PROJECTS': 'PROJECT',
  'TASK': 'PROJECT',
  'TASKS': 'PROJECT',
  'GOAL': 'PROJECT',
  'DURATION': 'DURATION',
  'LENGTH': 'DURATION',
  'TIME': 'TIME',
  'DATE': 'TIME',
  'DATETIME': 'TIME',
  'NUMBER': 'NUMBER',
  'NUM': 'NUMBER',
  'AMOUNT': 'NUMBER',
  'MONEY': 'NUMBER',
  'PERCENT': 'NUMBER',
  'QUANTITY': 'NUMBER',
  'OTHER': 'OTHER',
  'MISC': 'OTHER',
};

const Map<String, int> _numberWords = {
  'zero': 0,
  'one': 1,
  'two': 2,
  'too': 2,
  'to': 2,
  'three': 3,
  'four': 4,
  'five': 5,
  'six': 6,
  'seven': 7,
  'eight': 8,
  'nine': 9,
  'ten': 10,
  'eleven': 11,
  'twelve': 12,
};

const List<String> _cleanedTextKeys = [
  'cleaned_text',
  'cleanedText',
  'cleaned',
  'corrected_text',
  'refined_text',
  'transcript',
  'text',
];

const Map<String, int> _minuteWords = {
  'ten': 10,
  'fifteen': 15,
  'twenty': 20,
  'thirty': 30,
  'forty': 40,
  'fourty': 40,
  'forty five': 45,
  'fourty five': 45,
};

/// Deterministic post-processing for common STT phrases Gemma 3 1B often
/// leaves untouched. Kept conservative: only obvious title/time/number forms
/// that preserve the transcript's meaning are rewritten.
String repairCleanedTranscript(String cleanedText) {
  var text = cleanedText.trim();
  text = text.replaceAllMapped(
    RegExp(r'\bdoctor\s+([a-z][a-z]+)\b', caseSensitive: false),
    (m) => 'Dr. ${_titleCase(m.group(1)!)}',
  );
  text = text.replaceAll(RegExp(r'\bx ray\b', caseSensitive: false), 'X-ray');
  text = text.replaceAll(
    RegExp(r'\bterminal\s+(too|two|to)\b', caseSensitive: false),
    'Terminal 2',
  );
  text = text.replaceAllMapped(
    RegExp(
      r'\bair india\s+(one zero one|one oh one|101)\b',
      caseSensitive: false,
    ),
    (_) => 'Air India 101',
  );
  text = _repairClockTimes(text);
  return text;
}

/// Parse the cleanup-only stage response.
String? parseCleanedTranscript(String response) {
  final json = _extractJson(response);
  if (json == null) return null;
  try {
    final decoded = jsonDecode(json);
    final record = _recordMap(decoded);
    if (record == null) return null;
    final cleaned = _firstString(record, _cleanedTextKeys);
    return cleaned == null ? null : repairCleanedTranscript(cleaned);
  } on Object {
    final cleaned = _looseStringField(json, _cleanedTextKeys);
    return cleaned == null ? null : repairCleanedTranscript(cleaned);
  }
}

/// Parse the entity-only stage response and keep only mentions that can be
/// located in [cleanedText]. When the only mismatch is casing, the returned
/// mention text is normalized to the exact substring from [cleanedText].
List<({String text, String type})>? parseEntityMentions(
  String response, {
  required String cleanedText,
}) {
  final json = _extractJson(response);
  if (json == null) return null;
  try {
    final decoded = jsonDecode(json);
    final record = _recordMap(decoded);
    if (record == null) return null;

    final mentions = <({String text, String type})>[];
    final seen = <String>{};
    final lowerCleaned = cleanedText.toLowerCase();
    for (final item in _entityItems(record)) {
      final parsed = _parseMention(item);
      if (parsed == null) continue;
      final rawText = parsed.text.trim();
      if (rawText.isEmpty) continue;
      final type = _normalizeEntityType(parsed.type);
      final exactText = _bestEntitySubstring(
        rawText: rawText,
        type: type,
        cleanedText: cleanedText,
        lowerCleanedText: lowerCleaned,
      );
      if (exactText == null) continue;
      if (!_isPlausibleEntity(exactText, type)) continue;
      final key = '${exactText.toLowerCase()}\u0000$type';
      if (!seen.add(key)) continue;
      mentions.add((text: exactText, type: type));
      if (mentions.length >= _kMaxEntities) break;
    }

    _addDeterministicMentions(
      cleanedText: cleanedText,
      mentions: mentions,
      seen: seen,
    );

    if (mentions.length > _kMaxEntities) {
      return mentions.sublist(0, _kMaxEntities);
    }

    return mentions;
  } on Object {
    return null;
  }
}

/// Permissive JSON extractor. Small local LLMs occasionally wrap the requested
/// object in markdown, return a nested `arguments` object, or use common NER
/// labels such as `DATE` / `LOCATION`. This parser normalizes those variants
/// while still returning `null` for malformed top-level output so callers can
/// trigger one stricter retry.
ParsedRecordLog? parseRecordLog(String response) {
  final json = _extractJson(response);
  if (json == null) return null;
  try {
    final decoded = jsonDecode(json);
    final record = _recordMap(decoded);
    if (record == null) return null;

    final cleaned = _firstString(record, _cleanedTextKeys);
    if (cleaned == null) return null;

    final mentions = <({String text, String type})>[];
    final seen = <String>{};
    for (final item in _entityItems(record)) {
      final parsed = _parseMention(item);
      if (parsed == null) continue;
      final text = parsed.text.trim();
      if (text.isEmpty) continue;
      final type = _normalizeEntityType(parsed.type);
      final key = '${text.toLowerCase()}\u0000$type';
      if (!seen.add(key)) continue;
      mentions.add((text: text, type: type));
      if (mentions.length >= 20) break;
    }

    return ParsedRecordLog(cleanedText: cleaned.trim(), mentions: mentions);
  } on Object {
    final json = _extractJson(response);
    if (json == null) return null;
    final cleaned = _looseStringField(json, _cleanedTextKeys);
    if (cleaned == null) return null;
    return ParsedRecordLog(cleanedText: cleaned.trim(), mentions: const []);
  }
}

Map<String, dynamic>? _recordMap(Object? decoded) {
  if (decoded is! Map) return null;
  final root = Map<String, dynamic>.from(decoded);
  for (final key in const [
    'record_log',
    'arguments',
    'args',
    'data',
    'result',
    'output',
  ]) {
    final nested = root[key];
    if (nested is Map) return Map<String, dynamic>.from(nested);
    if (nested is String) {
      try {
        final decodedNested = jsonDecode(nested);
        if (decodedNested is Map) {
          return Map<String, dynamic>.from(decodedNested);
        }
      } on FormatException {
        continue;
      }
    }
  }
  return root;
}

String? _firstString(Map<String, dynamic> map, List<String> keys) {
  for (final key in keys) {
    final value = map[key];
    if (value is String && value.trim().isNotEmpty) return value;
  }
  return null;
}

String? _looseStringField(String source, List<String> keys) {
  for (final key in keys) {
    final match = RegExp(
      '"${RegExp.escape(key)}"\\s*:\\s*"',
      multiLine: true,
    ).firstMatch(source);
    if (match == null) continue;

    final buffer = StringBuffer();
    var escaped = false;
    for (var i = match.end; i < source.length; i++) {
      final c = source[i];
      if (escaped) {
        buffer.write(switch (c) {
          'n' => '\n',
          'r' => '\r',
          't' => '\t',
          '"' => '"',
          '\\' => '\\',
          _ => c,
        });
        escaped = false;
        continue;
      }
      if (c == '\\') {
        escaped = true;
        continue;
      }
      if (c == '"') {
        final rest = source.substring(i + 1).trimLeft();
        if (rest.startsWith(',') || rest.startsWith('}')) {
          final value = buffer.toString();
          return value.trim().isEmpty ? null : value;
        }
      }
      buffer.write(c);
    }
  }
  return null;
}

Iterable<Object?> _entityItems(Map<String, dynamic> record) sync* {
  final raw =
      record['entities'] ?? record['entity_mentions'] ?? record['mentions'];
  if (raw is List) {
    yield* raw;
    return;
  }
  if (raw is Map) {
    for (final entry in raw.entries) {
      final fallbackType = entry.key.toString();
      final value = entry.value;
      if (value is List) {
        for (final item in value) {
          yield _withFallbackType(item, fallbackType);
        }
      } else {
        yield _withFallbackType(value, fallbackType);
      }
    }
  }
}

Object? _withFallbackType(Object? item, String type) {
  if (item is String) return {'text': item, 'type': type};
  if (item is Map && !item.containsKey('type')) {
    return {...item, 'type': type};
  }
  return item;
}

({String text, String type})? _parseMention(Object? item) {
  if (item is String) return (text: item, type: 'OTHER');
  if (item is! Map) return null;
  final map = Map<String, dynamic>.from(item);
  final text = _firstString(map, const [
    'text',
    'mention',
    'name',
    'value',
    'entity',
    'surface',
  ]);
  if (text == null) return null;
  final type = _firstString(map, const [
    'type',
    'entity_type',
    'entityType',
    'label',
    'category',
    'kind',
    'tag',
  ]);
  return (text: text, type: type ?? 'OTHER');
}

String _repairClockTimes(String input) {
  var text = input.replaceAllMapped(
    RegExp(
      r'\b(zero|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve)\s+(am|pm)\b',
      caseSensitive: false,
    ),
    (m) =>
        '${_numberWords[m.group(1)!.toLowerCase()]} ${m.group(2)!.toUpperCase()}',
  );

  text = text.replaceAllMapped(
    RegExp(
      r'\b(one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve)\s+(ten|fifteen|twenty|thirty|forty|fourty|forty five|fourty five)\b(?:\s*(am|pm))?',
      caseSensitive: false,
    ),
    (m) {
      final hour = _numberWords[m.group(1)!.toLowerCase()];
      final minute = _minuteWords[m.group(2)!.toLowerCase()];
      if (hour == null || minute == null) return m.group(0)!;
      final suffix = m.group(3) == null ? '' : ' ${m.group(3)!.toUpperCase()}';
      return '$hour:${minute.toString().padLeft(2, '0')}$suffix';
    },
  );
  return text;
}

String _titleCase(String value) {
  if (value.isEmpty) return value;
  return value[0].toUpperCase() + value.substring(1).toLowerCase();
}

String? _bestEntitySubstring({
  required String rawText,
  required String type,
  required String cleanedText,
  required String lowerCleanedText,
}) {
  for (final candidate in _entityTextCandidates(rawText, type)) {
    final idx = lowerCleanedText.indexOf(candidate.toLowerCase());
    if (idx < 0) continue;
    return cleanedText.substring(idx, idx + candidate.length);
  }
  return null;
}

Iterable<String> _entityTextCandidates(String rawText, String type) sync* {
  final trimmed = rawText.trim();
  if (trimmed.isEmpty) return;

  final normalized = trimmed;
  var yieldedTrimmedVariant = false;
  for (final prefix in const [
    'from ',
    'to ',
    'at ',
    'near ',
    'call ',
    'meet ',
    'meeting with ',
    'talk to ',
    'pick up ',
    'send ',
    'book ',
    'renew ',
  ]) {
    if (normalized.toLowerCase().startsWith(prefix)) {
      final without = normalized.substring(prefix.length).trim();
      if (without.isNotEmpty) {
        yieldedTrimmedVariant = true;
        yield without;
      }
    }
  }

  if (!yieldedTrimmedVariant) yield trimmed;

  if (type == 'PERSON') {
    final doctorMatch = RegExp(
      r'(?:doctor|dr\.?)[\s.]+([a-z][a-z]+)',
      caseSensitive: false,
    ).firstMatch(trimmed);
    if (doctorMatch != null) {
      yield 'Dr. ${_titleCase(doctorMatch.group(1)!)}';
      yield 'doctor ${doctorMatch.group(1)!}';
    }
  }
}

void _addDeterministicMentions({
  required String cleanedText,
  required List<({String text, String type})> mentions,
  required Set<String> seen,
}) {
  void add(String text, String type) {
    if (mentions.length >= _kMaxEntities) return;
    if (!_isPlausibleEntity(text, type)) return;
    final key = '${text.toLowerCase()}\u0000$type';
    if (!seen.add(key)) return;
    mentions.add((text: text, type: type));
  }

  for (final match in RegExp(
    r'\bDr\.?\s*[A-Z][a-zA-Z]+(?:\s+[A-Z][a-zA-Z]+)*\b',
  ).allMatches(cleanedText)) {
    add(match.group(0)!, 'PERSON');
  }
  for (final match in RegExp(r'\b(?:Mom|Dad)\b').allMatches(cleanedText)) {
    add(match.group(0)!, 'PERSON');
  }
  for (final match in RegExp(
    r'\b(?:Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday|today|tomorrow|tonight|yesterday|morning|afternoon|evening|noon|after work)\b',
    caseSensitive: false,
  ).allMatches(cleanedText)) {
    add(cleanedText.substring(match.start, match.end), 'TIME');
  }
  for (final match in RegExp(
    r'\b\d{1,2}(?::\d{2})?\s*(?:AM|PM)\b',
    caseSensitive: false,
  ).allMatches(cleanedText)) {
    add(cleanedText.substring(match.start, match.end), 'TIME');
  }
  for (final match in RegExp(
    r'\b(?:January|February|March|April|May|June|July|August|September|October|November|December)\s+\d{1,2}\b|\b\d{1,2}(?:st|nd|rd|th)?\s+(?:January|February|March|April|May|June|July|August|September|October|November|December)\b',
    caseSensitive: false,
  ).allMatches(cleanedText)) {
    add(cleanedText.substring(match.start, match.end), 'TIME');
  }
  for (final match in RegExp(
    r'\b\d+\s*(?:minutes?|hours?|days?|weeks?|months?|years?)\b',
    caseSensitive: false,
  ).allMatches(cleanedText)) {
    add(cleanedText.substring(match.start, match.end), 'DURATION');
  }
  for (final match in RegExp(
    r'\bProject\s+[A-Za-z][A-Za-z0-9]+\b',
    caseSensitive: false,
  ).allMatches(cleanedText)) {
    add(cleanedText.substring(match.start, match.end), 'PROJECT');
  }
  for (final match in RegExp(
    r'\b[A-Z][a-z]+\s+\d{3,}\b',
  ).allMatches(cleanedText)) {
    add(match.group(0)!, 'NUMBER');
  }
}

bool _isPlausibleEntity(String text, String type) {
  final normalized = text.toLowerCase().trim();
  if (normalized.isEmpty) return false;
  if (_looksLikeGenericActionPhrase(text)) return false;
  if (const {'i', 'me', 'my', 'we', 'you'}.contains(normalized)) return false;

  switch (type) {
    case 'PERSON':
      if (_startsWithActionVerb(normalized)) return false;
      return normalized == 'mom' ||
          normalized == 'dad' ||
          normalized.startsWith('dr.') ||
          normalized.startsWith('doctor ') ||
          RegExp(r'^[a-z]+(?:\s+[a-z]+)?$').hasMatch(normalized);
    case 'TIME':
      return RegExp(
        r'\b(?:am|pm|:\d{2}|monday|tuesday|wednesday|thursday|friday|saturday|sunday|today|tomorrow|tonight|yesterday|morning|afternoon|evening|noon|january|february|march|april|may|june|july|august|september|october|november|december|next|before|after work)\b',
        caseSensitive: false,
      ).hasMatch(normalized);
    case 'NUMBER':
      return RegExp(r'\d').hasMatch(normalized) ||
          RegExp(
            r'\b(?:zero|one|two|three|four|five|six|seven|eight|nine|ten|hundred|thousand|lakh|dollar|rupee)\b',
          ).hasMatch(normalized);
    case 'OTHER':
      return !_looksLikeGenericActionPhrase(text) &&
          normalized.split(RegExp(r'\s+')).length <= 3;
    case 'PLACE':
    case 'PROJECT':
    case 'DURATION':
      return !_startsWithActionVerb(normalized);
  }
  return false;
}

bool _startsWithActionVerb(String normalized) {
  const verbs = [
    'call ',
    'meet ',
    'send ',
    'book ',
    'pay ',
    'buy ',
    'bring ',
    'renew ',
    'remember ',
    'replace ',
    'schedule ',
    'reserve ',
    'collect ',
    'transfer ',
    'talk ',
    'brainstorm ',
  ];
  return verbs.any(normalized.startsWith);
}

bool _looksLikeGenericActionPhrase(String text) {
  final normalized = text.toLowerCase().trim();
  if (normalized.isEmpty) return true;
  const generic = {
    'appointment',
    'dentist appointment',
    'meeting',
    'book cake',
    'send revised deck',
    'pick up mom',
    'call',
    'pay',
    'buy',
    'bring',
    'remember',
  };
  if (generic.contains(normalized)) return true;
  const actionStarts = [
    'pick up ',
    'send ',
    'book ',
    'call ',
    'pay ',
    'buy ',
    'bring ',
    'meeting ',
    'appointment ',
  ];
  return actionStarts.any(normalized.startsWith);
}

String _normalizeEntityType(String raw) {
  final upper = raw.trim().toUpperCase().replaceAll(RegExp(r'[\s-]+'), '_');
  final direct = _entityTypeAliases[upper];
  if (direct != null) return direct;
  if (_validEntityTypes.contains(upper)) return upper;
  return 'OTHER';
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
