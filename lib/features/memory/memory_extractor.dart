import 'dart:convert';

import '../../core/app_error.dart';
import '../../core/result.dart';
import '../refine/llm_runner.dart';
import 'memory_prompt_templates.dart';
import 'memory_types.dart';

/// Confidence assigned to first-seen memories. Below the 0.85 auto-activate
/// threshold so new memories start as candidates; the dedup/boost layer in
/// MemoryRepository promotes them when repeated evidence appears.
const double kDefaultFirstSeenConfidence = 0.8;

/// Default maximum number of memories extracted from a single log.
const int kMaxMemoriesPerLog = 5;

/// Scale the memory cap with transcript length.
int maxMemoriesForLength(int charCount) {
  if (charCount < 500) return 3;
  if (charCount < 1500) return 5;
  if (charCount < 3000) return 8;
  return 10;
}

/// Errors from local memory extraction.
sealed class MemoryExtractionError extends AppError {
  const MemoryExtractionError({
    required super.message,
    super.cause,
    super.stack,
  });
}

/// LLM failed to load or generate.
final class MemoryExtractionLlmError extends MemoryExtractionError {
  const MemoryExtractionLlmError({
    required super.message,
    super.cause,
    super.stack,
  });
}

/// Model output could not be parsed even after retry.
final class MemoryExtractionParseError extends MemoryExtractionError {
  const MemoryExtractionParseError({required super.message});
}

/// Runs Gemma and validates durable memory candidates. Persistence is handled
/// by `MemoryRepository` so tests can exercise extraction independently.
class MemoryExtractor {
  MemoryExtractor({required LlmRunner runner, int maxMemoriesPerLog = 10})
    : _runner = runner,
      _maxMemoriesPerLog = maxMemoriesPerLog;

  final LlmRunner _runner;
  final int _maxMemoriesPerLog;

  /// Extract validated memory candidates from [cleanedText]. Empty logs produce
  /// an empty success result.
  /// Extract validated memory candidates from [cleanedText]. The runner's idle
  /// TTL handles model lifecycle — callers must not force-unload.
  Future<Result<List<MemoryCandidate>, MemoryExtractionError>> extract(
    String cleanedText,
  ) async {
    if (cleanedText.trim().isEmpty) return const Ok([]);
    return _extractWithModel(cleanedText);
  }

  Future<Result<List<MemoryCandidate>, MemoryExtractionError>>
  _extractWithModel(String cleanedText) async {
    final loaded = await _runner.load();
    switch (loaded) {
      case Ok():
        break;
      case Err(:final error):
        return Err(
          MemoryExtractionLlmError(
            message: 'Failed to load memory LLM: ${error.message}',
            cause: error.cause,
            stack: error.stack,
          ),
        );
    }

    final effectiveMax = maxMemoriesForLength(
      cleanedText.length,
    ).clamp(1, _maxMemoriesPerLog);
    final first = await _runner.generate(
      memoryExtractionPrompt(cleanedText, maxMemories: effectiveMax),
      temperature: 0.2,
    );
    String raw;
    switch (first) {
      case Ok(:final value):
        raw = value;
      case Err(:final error):
        return Err(
          MemoryExtractionLlmError(
            message: 'Failed to extract memories: ${error.message}',
            cause: error.cause,
            stack: error.stack,
          ),
        );
    }

    var parsed = parseMemoryCandidates(
      raw,
      cleanedText: cleanedText,
      maxMemories: effectiveMax,
    );
    if (parsed != null) return Ok(parsed);

    final retry = await _runner.generate(
      memoryExtractionRetryPrompt(cleanedText, raw),
      temperature: 0.1,
    );
    switch (retry) {
      case Ok(:final value):
        parsed = parseMemoryCandidates(
          value,
          cleanedText: cleanedText,
          maxMemories: effectiveMax,
        );
      case Err(:final error):
        return Err(
          MemoryExtractionLlmError(
            message: 'Failed to retry memory extraction: ${error.message}',
            cause: error.cause,
            stack: error.stack,
          ),
        );
    }

    if (parsed == null) {
      // Memory is opportunistic. Invalid structured output should not fail the
      // voice-log pipeline or retry forever; keep the source log and continue
      // without extracted memories for this run.
      return const Ok([]);
    }
    return Ok(parsed);
  }
}

/// Parse and validate Gemma memory JSON. Invalid top-level JSON returns null;
/// invalid individual memories are dropped. Confidence and sensitivity are
/// optional in the model output — defaults are assigned in Dart so the 1B
/// model has fewer fields to generate.
List<MemoryCandidate>? parseMemoryCandidates(
  String response, {
  required String cleanedText,
  int maxMemories = kMaxMemoriesPerLog,
}) {
  final json = _extractJson(response);
  if (json == null) return null;
  try {
    final decoded = jsonDecode(json);
    final rawMemories = _memoryItems(decoded);
    if (rawMemories == null) return null;

    final out = <MemoryCandidate>[];
    for (final raw in rawMemories) {
      if (out.length >= maxMemories) break;
      final map = _asStringKeyedMap(raw);
      if (map == null) continue;
      final typeRaw = _firstString(map, const ['type', 'category', 'kind']);
      final textRaw = _firstString(map, const [
        'text',
        'memory',
        'summary',
        'content',
      ]);
      final evidenceRaw = _firstString(map, const [
        'evidence',
        'quote',
        'source_text',
        'sourceText',
      ]);
      if (typeRaw == null || textRaw == null || evidenceRaw == null) {
        continue;
      }

      final type = _parseMemoryType(typeRaw);
      if (type == null) continue;
      final text = textRaw.trim();
      final evidence = evidenceRaw.trim();
      if (text.isEmpty || evidence.isEmpty) continue;

      final confidenceRaw = map['confidence'] ?? map['score'];
      final confidence =
          _parseConfidence(confidenceRaw) ?? kDefaultFirstSeenConfidence;

      final sensitivityRaw = _firstString(map, const [
        'sensitivity',
        'privacy',
      ]);
      final sensitivity =
          (sensitivityRaw != null ? _parseSensitivity(sensitivityRaw) : null) ??
          _detectSensitivity(text, evidence);

      final span = _findEvidenceSpan(cleanedText, evidence);
      if (span == null) continue;
      out.add(
        MemoryCandidate(
          type: type,
          text: text,
          evidence: cleanedText.substring(span.start, span.end),
          confidence: confidence,
          sensitivity: sensitivity,
          startChar: span.start,
          endChar: span.end,
        ),
      );
    }
    return out;
  } on FormatException {
    return null;
  }
}

List<Object?>? _memoryItems(Object? decoded) {
  if (decoded is List) return decoded;
  final root = _asStringKeyedMap(decoded);
  if (root == null) return null;

  for (final key in const [
    'memories',
    'memory_candidates',
    'memoryCandidates',
    'candidates',
    'items',
    'results',
  ]) {
    final value = root[key];
    if (value is List) return value;
  }

  for (final key in const ['arguments', 'args', 'data', 'result', 'output']) {
    final nested = root[key];
    final nestedMap = _asStringKeyedMap(nested);
    if (nestedMap != null) {
      final nestedItems = _memoryItems(nestedMap);
      if (nestedItems != null) return nestedItems;
    }
    if (nested is String) {
      try {
        final decodedNested = jsonDecode(nested);
        final nestedItems = _memoryItems(decodedNested);
        if (nestedItems != null) return nestedItems;
      } on FormatException {
        continue;
      }
    }
  }

  return null;
}

Map<String, dynamic>? _asStringKeyedMap(Object? value) {
  if (value is! Map) return null;
  return Map<String, dynamic>.from(value);
}

String? _firstString(Map<String, dynamic> map, List<String> keys) {
  for (final key in keys) {
    final value = map[key];
    if (value is String && value.trim().isNotEmpty) return value;
  }
  return null;
}

MemoryType? _parseMemoryType(String raw) {
  final normalized = raw.trim().toLowerCase().replaceAll('-', '_');
  final direct = MemoryType.fromWireOrNull(normalized);
  if (direct != null) return direct;
  return switch (normalized) {
    'fact' => MemoryType.identity,
    'person' => MemoryType.relationship,
    'habit' => MemoryType.routine,
    'plan' => MemoryType.project,
    _ => null,
  };
}

MemorySensitivity? _parseSensitivity(String raw) {
  final normalized = raw.trim().toLowerCase().replaceAll('-', '_');
  return MemorySensitivity.fromWireOrNull(normalized);
}

const _sensitiveTerms = [
  'doctor',
  'medical',
  'clinic',
  'cardiol',
  'oncol',
  'neurolog',
  'therapy',
  'therapist',
  'counseling',
  'medication',
  'prescription',
  'diagnosis',
  'surgery',
  'hospital',
  'psychiatr',
  'salary',
  'debt',
  'loan',
  'mortgage',
  'bank account',
  'credit card',
  'addiction',
  'rehab',
];

MemorySensitivity _detectSensitivity(String text, String evidence) {
  final combined = '${text.toLowerCase()} ${evidence.toLowerCase()}';
  for (final term in _sensitiveTerms) {
    if (combined.contains(term)) return MemorySensitivity.sensitive;
  }
  return MemorySensitivity.normal;
}

double? _parseConfidence(Object? raw) {
  final double? value = switch (raw) {
    num() => raw.toDouble(),
    String() => double.tryParse(raw.trim()),
    _ => null,
  };
  if (value == null) return null;
  final normalized = (value > 1.0 && value <= 100.0) ? value / 100.0 : value;
  return normalized.clamp(0, 1).toDouble();
}

({int start, int end})? _findEvidenceSpan(String cleanedText, String evidence) {
  final exact = cleanedText.indexOf(evidence);
  if (exact >= 0) return (start: exact, end: exact + evidence.length);

  final lowerText = cleanedText.toLowerCase();
  final lowerEvidence = evidence.toLowerCase();
  final folded = lowerText.indexOf(lowerEvidence);
  if (folded >= 0) {
    return (start: folded, end: folded + evidence.length);
  }

  final normText = _normalizeForMatch(cleanedText);
  final normEvidence = _normalizeForMatch(evidence);
  final normIdx = normText.indexOf(normEvidence);
  if (normIdx >= 0) {
    final span = _mapNormalizedOffset(
      cleanedText,
      normIdx,
      normEvidence.length,
    );
    if (span != null) return span;
  }
  return null;
}

String _normalizeForMatch(String text) {
  return text
      .toLowerCase()
      .replaceAll("'m ", ' am ')
      .replaceAll("'re ", ' are ')
      .replaceAll("'ve ", ' have ')
      .replaceAll("'ll ", ' will ')
      .replaceAll("'d ", ' would ')
      .replaceAll("n't ", ' not ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

({int start, int end})? _mapNormalizedOffset(
  String original,
  int normStart,
  int normLen,
) {
  final normOriginal = _normalizeForMatch(original);
  if (normStart + normLen > normOriginal.length) return null;
  var origIdx = 0;
  var normIdx = 0;
  final origLower = original.toLowerCase();
  final normChars = normOriginal;
  int? startOrig;
  while (origIdx < original.length && normIdx < normChars.length) {
    if (normIdx == normStart && startOrig == null) {
      startOrig = origIdx;
    }
    if (normIdx == normStart + normLen) {
      return (start: startOrig!, end: origIdx);
    }
    final oc = origLower[origIdx];
    final nc = normChars[normIdx];
    if (oc == nc) {
      origIdx++;
      normIdx++;
    } else {
      origIdx++;
    }
  }
  if (normIdx == normStart + normLen && startOrig != null) {
    return (start: startOrig, end: origIdx);
  }
  return null;
}

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
      if (depth == 0) return response.substring(firstBrace, i + 1);
    }
  }
  return null;
}
