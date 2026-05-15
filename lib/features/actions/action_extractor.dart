import 'dart:convert';

import '../../core/app_error.dart';
import '../../core/result.dart';
import '../refine/llm_runner.dart';
import 'action_prompt_templates.dart';
import 'action_types.dart';

/// Default maximum number of action items extracted from a single log.
const int kMaxActionsPerLog = 8;

/// Errors from local action extraction.
sealed class ActionExtractionError extends AppError {
  const ActionExtractionError({
    required super.message,
    super.cause,
    super.stack,
  });
}

/// LLM load or generation failed.
final class ActionExtractionLlmError extends ActionExtractionError {
  const ActionExtractionLlmError({
    required super.message,
    super.cause,
    super.stack,
  });
}

/// Model output could not be parsed.
final class ActionExtractionParseError extends ActionExtractionError {
  const ActionExtractionParseError({required super.message});
}

/// Extracts tasks, reminders, decisions, and follow-ups from cleaned logs.
class ActionExtractor {
  ActionExtractor({
    required LlmRunner runner,
    DateTime Function()? now,
    int maxActionsPerLog = kMaxActionsPerLog,
  }) : _runner = runner,
       _now = now ?? DateTime.now,
       _maxActionsPerLog = maxActionsPerLog;

  final LlmRunner _runner;
  final DateTime Function() _now;
  final int _maxActionsPerLog;

  /// Extract validated action candidates. Empty logs produce an empty success.
  Future<Result<List<VoiceActionCandidate>, ActionExtractionError>> extract(
    String cleanedText,
  ) async {
    if (cleanedText.trim().isEmpty) return const Ok([]);

    final loaded = await _runner.load();
    switch (loaded) {
      case Ok():
        break;
      case Err(:final error):
        return Err(
          ActionExtractionLlmError(
            message: 'Failed to load action LLM: ${error.message}',
            cause: error.cause,
            stack: error.stack,
          ),
        );
    }

    final now = _now();
    final first = await _runner.generate(
      actionExtractionPrompt(cleanedText: cleanedText, now: now),
      temperature: kActionExtractionTemperature,
    );
    String raw;
    switch (first) {
      case Ok(:final value):
        raw = value;
      case Err(:final error):
        return Err(
          ActionExtractionLlmError(
            message: 'Failed to extract actions: ${error.message}',
            cause: error.cause,
            stack: error.stack,
          ),
        );
    }

    var parsed = parseActionCandidates(
      raw,
      cleanedText: cleanedText,
      maxActions: _maxActionsPerLog,
    );
    if (parsed != null) return Ok(parsed);

    final retry = await _runner.generate(
      actionExtractionRetryPrompt(
        cleanedText: cleanedText,
        previousResponse: raw,
        now: now,
      ),
      temperature: 0,
    );
    switch (retry) {
      case Ok(:final value):
        parsed = parseActionCandidates(
          value,
          cleanedText: cleanedText,
          maxActions: _maxActionsPerLog,
        );
      case Err(:final error):
        return Err(
          ActionExtractionLlmError(
            message: 'Failed to retry action extraction: ${error.message}',
            cause: error.cause,
            stack: error.stack,
          ),
        );
    }

    // Action extraction is opportunistic and should not fail the pipeline.
    return Ok(parsed ?? const []);
  }
}

/// Parse and validate action JSON. Invalid top-level JSON returns null;
/// invalid individual action objects are dropped.
List<VoiceActionCandidate>? parseActionCandidates(
  String response, {
  required String cleanedText,
  int maxActions = kMaxActionsPerLog,
}) {
  final json = _extractJson(response);
  if (json == null) return null;
  try {
    final decoded = jsonDecode(json);
    final rawActions = _actionItems(decoded);
    if (rawActions == null) return null;

    final out = <VoiceActionCandidate>[];
    for (final raw in rawActions) {
      if (out.length >= maxActions) break;
      final map = _asStringKeyedMap(raw);
      if (map == null) continue;
      final typeRaw = _firstString(map, const ['type', 'kind', 'category']);
      final titleRaw = _firstString(map, const ['title', 'task', 'action']);
      final evidenceRaw = _firstString(map, const [
        'evidence',
        'quote',
        'source_text',
        'sourceText',
      ]);
      if (typeRaw == null || titleRaw == null || evidenceRaw == null) {
        continue;
      }

      final type = _parseActionType(typeRaw);
      if (type == null) continue;
      final title = titleRaw.trim();
      final evidence = evidenceRaw.trim();
      if (title.isEmpty || evidence.isEmpty) continue;

      final span = _findEvidenceSpan(cleanedText, evidence);
      if (span == null) continue;

      final confidence =
          _parseConfidence(map['confidence'] ?? map['score']) ?? 0.8;
      final notes = _firstString(map, const ['notes', 'details']);
      final dueAt = _parseDueAt(
        _firstString(map, const ['due_at', 'dueAt', 'deadline', 'remind_at']),
      );

      out.add(
        VoiceActionCandidate(
          type: dueAt != null && type == VoiceActionType.task
              ? VoiceActionType.reminder
              : type,
          title: title,
          notes: notes?.trim(),
          dueAt: dueAt,
          evidence: cleanedText.substring(span.start, span.end),
          startChar: span.start,
          endChar: span.end,
          confidence: confidence,
        ),
      );
    }
    return out;
  } on FormatException {
    return null;
  }
}

List<Object?>? _actionItems(Object? decoded) {
  if (decoded is List) return decoded;
  final root = _asStringKeyedMap(decoded);
  if (root == null) return null;
  for (final key in const ['actions', 'items', 'tasks', 'results']) {
    final value = root[key];
    if (value is List) return value;
  }
  for (final key in const ['arguments', 'args', 'data', 'result', 'output']) {
    final nested = root[key];
    final nestedMap = _asStringKeyedMap(nested);
    if (nestedMap != null) {
      final nestedItems = _actionItems(nestedMap);
      if (nestedItems != null) return nestedItems;
    }
    if (nested is String) {
      try {
        final nestedItems = _actionItems(jsonDecode(nested));
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

VoiceActionType? _parseActionType(String raw) {
  final normalized = raw.trim().toLowerCase().replaceAll('-', '_');
  final direct = VoiceActionType.fromWireOrNull(normalized);
  if (direct != null) return direct;
  return switch (normalized) {
    'todo' => VoiceActionType.task,
    'to_do' => VoiceActionType.task,
    'followup' => VoiceActionType.followUp,
    'follow_up' => VoiceActionType.followUp,
    _ => null,
  };
}

DateTime? _parseDueAt(String? raw) {
  if (raw == null) return null;
  final normalized = raw.trim();
  if (normalized.isEmpty || normalized.toLowerCase() == 'null') return null;
  return DateTime.tryParse(normalized);
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
  if (folded >= 0) return (start: folded, end: folded + evidence.length);

  final normText = _normalizeForMatch(cleanedText);
  final normEvidence = _normalizeForMatch(evidence);
  final normIdx = normText.indexOf(normEvidence);
  if (normIdx < 0) return null;
  return _mapNormalizedOffset(cleanedText, normIdx, normEvidence.length);
}

String _normalizeForMatch(String text) {
  return text
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

({int start, int end})? _mapNormalizedOffset(
  String original,
  int normStart,
  int normLen,
) {
  final target = _normalizeForMatch(original);
  if (normStart + normLen > target.length) return null;
  var origIdx = 0;
  var normIdx = 0;
  final lower = original.toLowerCase();
  int? startOrig;
  while (origIdx < original.length && normIdx < target.length) {
    if (normIdx == normStart && startOrig == null) startOrig = origIdx;
    if (normIdx == normStart + normLen) {
      return (start: startOrig!, end: origIdx);
    }
    final oc = lower[origIdx];
    final isWord = RegExp(r'[a-z0-9]').hasMatch(oc);
    final normalizedChar = isWord ? oc : ' ';
    if (normalizedChar == target[normIdx]) {
      origIdx++;
      normIdx++;
      while (normIdx < target.length &&
          target[normIdx] == ' ' &&
          origIdx < original.length &&
          !RegExp(r'[a-z0-9]').hasMatch(lower[origIdx])) {
        origIdx++;
      }
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
