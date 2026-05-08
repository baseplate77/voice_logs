import 'dart:convert';

import '../../core/app_error.dart';
import '../../core/result.dart';
import '../refine/llm_runner.dart';
import 'memory_prompt_templates.dart';
import 'memory_types.dart';

/// Minimum confidence accepted from Gemma for automatic memory persistence.
const double kMemoryExtractionConfidenceThreshold = 0.7;

/// Maximum number of memories extracted from a single log.
const int kMaxMemoriesPerLog = 5;

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
  MemoryExtractor({
    required LlmRunner runner,
    double confidenceThreshold = kMemoryExtractionConfidenceThreshold,
    int maxMemoriesPerLog = kMaxMemoriesPerLog,
  }) : _runner = runner,
       _confidenceThreshold = confidenceThreshold,
       _maxMemoriesPerLog = maxMemoriesPerLog;

  final LlmRunner _runner;
  final double _confidenceThreshold;
  final int _maxMemoriesPerLog;

  /// Extract validated memory candidates from [cleanedText]. Empty logs produce
  /// an empty success result.
  Future<Result<List<MemoryCandidate>, MemoryExtractionError>> extract(
    String cleanedText,
  ) async {
    if (cleanedText.trim().isEmpty) return const Ok([]);
    try {
      return await _extractWithModel(cleanedText);
    } finally {
      await _runner.unload();
    }
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

    final first = await _runner.generate(
      memoryExtractionPrompt(cleanedText),
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
      confidenceThreshold: _confidenceThreshold,
      maxMemories: _maxMemoriesPerLog,
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
          confidenceThreshold: _confidenceThreshold,
          maxMemories: _maxMemoriesPerLog,
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
      return const Err(
        MemoryExtractionParseError(
          message: 'Memory extraction did not return valid JSON candidates',
        ),
      );
    }
    return Ok(parsed);
  }
}

/// Parse and validate Gemma memory JSON. Invalid top-level JSON returns null;
/// invalid individual memories are dropped.
List<MemoryCandidate>? parseMemoryCandidates(
  String response, {
  required String cleanedText,
  double confidenceThreshold = kMemoryExtractionConfidenceThreshold,
  int maxMemories = kMaxMemoriesPerLog,
}) {
  final json = _extractJson(response);
  if (json == null) return null;
  try {
    final decoded = jsonDecode(json);
    if (decoded is! Map<String, dynamic>) return null;
    final rawMemories = decoded['memories'];
    if (rawMemories is! List) return null;

    final out = <MemoryCandidate>[];
    for (final raw in rawMemories) {
      if (out.length >= maxMemories) break;
      if (raw is! Map<String, dynamic>) continue;
      final typeRaw = raw['type'];
      final textRaw = raw['text'];
      final evidenceRaw = raw['evidence'];
      final confidenceRaw = raw['confidence'];
      final sensitivityRaw = raw['sensitivity'];
      if (typeRaw is! String ||
          textRaw is! String ||
          evidenceRaw is! String ||
          sensitivityRaw is! String ||
          confidenceRaw is! num) {
        continue;
      }

      final type = MemoryType.fromWireOrNull(typeRaw);
      final sensitivity = MemorySensitivity.fromWireOrNull(sensitivityRaw);
      if (type == null || sensitivity == null) continue;
      final text = textRaw.trim();
      final evidence = evidenceRaw.trim();
      if (text.isEmpty || evidence.isEmpty) continue;
      final confidence = confidenceRaw.toDouble().clamp(0, 1).toDouble();
      if (confidence < confidenceThreshold) continue;

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

({int start, int end})? _findEvidenceSpan(String cleanedText, String evidence) {
  final exact = cleanedText.indexOf(evidence);
  if (exact >= 0) return (start: exact, end: exact + evidence.length);

  final lowerText = cleanedText.toLowerCase();
  final lowerEvidence = evidence.toLowerCase();
  final folded = lowerText.indexOf(lowerEvidence);
  if (folded >= 0) {
    return (start: folded, end: folded + evidence.length);
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
