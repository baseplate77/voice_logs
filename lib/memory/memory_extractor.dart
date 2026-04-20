import 'dart:convert';

import '../core/errors.dart';
import '../core/logger.dart';
import '../core/result.dart';
import '../llm/llm_runner.dart';
import '../llm/models/cleaned_transcript.dart';
import '../store/models/voice_log_record.dart';
import 'models/memory.dart';
import 'models/memory_candidate.dart';
import 'prompts/memory_extraction.dart';

/// Temperature for extraction. Low for determinism — same transcript
/// should yield (roughly) the same memory set on re-run, matching the
/// rest of the stack's `kBackgroundJobTemperature = 0.2`.
const double kMemoryExtractionTemperature = 0.2;

/// Minimum confidence the extractor admits. Anything below is dropped
/// at the parser; the prompt also instructs Gemma not to emit these.
const double kMemoryExtractionMinConfidence = 0.5;

/// Turn a [CleanedTranscript] into a list of [MemoryCandidate]s via one
/// Gemma call + strict JSON parse + single retry on malformed output.
///
/// Not an interface — there's one production implementation and a fake
/// for tests follows the same constructor contract + injected runner.
class MemoryExtractor {
  MemoryExtractor({
    required this.runner,
    AppLogger? logger,
    DateTime Function()? clock,
  })  : _logger = logger ?? AppLogger(),
        _now = clock ?? DateTime.now;

  final LlmRunner runner;
  final AppLogger _logger;
  final DateTime Function() _now;

  /// Extract candidates. Returns `Ok([])` on any non-fatal failure
  /// (malformed JSON after retry, empty output); propagates LLM-level
  /// errors (model unavailable, etc.) as [Err].
  ///
  /// [chunks] must come from the same voice log as [cleaned]; the
  /// extractor uses their ids + text to attach provenance to each
  /// candidate.
  Future<Result<List<MemoryCandidate>, AppError>> extract({
    required CleanedTranscript cleaned,
    required List<ChunkRecord> chunks,
    DateTime? recordingDate,
  }) async {
    if (cleaned.text.trim().isEmpty) {
      return const Ok<List<MemoryCandidate>, AppError>(<MemoryCandidate>[]);
    }

    final dateStr = _formatYmd(recordingDate ?? _now());
    final entitiesBlock = _formatEntities(cleaned.entities);

    final firstPrompt = memoryExtractionTemplate.render(<String, String>{
      'recording_date': dateStr,
      'entities': entitiesBlock,
      'transcript': cleaned.text,
    });

    final firstR = await runner.generateSync(
      firstPrompt,
      temperatureOverride: kMemoryExtractionTemperature,
    );
    if (firstR.isErr) {
      return Err<List<MemoryCandidate>, AppError>(firstR.errOrNull!);
    }

    var parsed = _parsePayload(firstR.okOrNull!);
    if (parsed == null) {
      _logger.warn(
        'MemoryExtractor: first pass JSON parse failed, retrying',
      );
      final retryPrompt =
          memoryExtractionRetryTemplate.render(<String, String>{
        'recording_date': dateStr,
        'transcript': cleaned.text,
      });
      final retryR = await runner.generateSync(
        retryPrompt,
        temperatureOverride: kMemoryExtractionTemperature,
      );
      if (retryR.isErr) {
        return Err<List<MemoryCandidate>, AppError>(retryR.errOrNull!);
      }
      parsed = _parsePayload(retryR.okOrNull!);
      if (parsed == null) {
        _logger.warn(
          'MemoryExtractor: retry JSON parse also failed; '
          'falling back to empty candidate list',
        );
        return const Ok<List<MemoryCandidate>, AppError>(<MemoryCandidate>[]);
      }
    }

    final candidates = <MemoryCandidate>[];
    for (final item in _asList(parsed['facts'])) {
      final c = _buildFact(item, chunks);
      if (c != null) candidates.add(c);
    }
    for (final item in _asList(parsed['decisions'])) {
      final c = _buildDecision(item, chunks, dateStr);
      if (c != null) candidates.add(c);
    }
    for (final item in _asList(parsed['episodes'])) {
      final c = _buildEpisode(item, chunks, dateStr);
      if (c != null) candidates.add(c);
    }
    for (final item in _asList(parsed['goals'])) {
      final c = _buildGoal(item, chunks);
      if (c != null) candidates.add(c);
    }

    return Ok<List<MemoryCandidate>, AppError>(candidates);
  }

  // ─── parsing ─────────────────────────────────────────────────────

  static List<Object?> _asList(Object? raw) =>
      raw is List ? raw.cast<Object?>() : const <Object?>[];

  static Map<String, dynamic>? _parsePayload(String raw) {
    final stripped = _stripCodeFences(raw);
    try {
      final decoded = jsonDecode(stripped);
      if (decoded is! Map) return null;
      return decoded.cast<String, dynamic>();
    } on FormatException {
      return null;
    }
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

  MemoryCandidate? _buildFact(dynamic raw, List<ChunkRecord> chunks) {
    final base = _commonFields(raw);
    if (base == null) return null;
    return MemoryCandidate(
      kind: MemoryKind.fact,
      title: base.title,
      content: base.content,
      confidence: base.confidence,
      sourceChunkIds: _resolveSourceChunks(base.content, chunks),
      entityNames: base.entityNames,
    );
  }

  MemoryCandidate? _buildDecision(
    dynamic raw,
    List<ChunkRecord> chunks,
    String recordingDate,
  ) {
    final base = _commonFields(raw);
    if (base == null) return null;
    if (raw is! Map) return null;
    final occurred = _parseDate(raw['occurred_at']) ?? _parseDate(recordingDate);
    if (occurred == null) return null;
    return MemoryCandidate(
      kind: MemoryKind.decision,
      title: base.title,
      content: base.content,
      confidence: base.confidence,
      sourceChunkIds: _resolveSourceChunks(base.content, chunks),
      entityNames: base.entityNames,
      occurredAt: occurred,
    );
  }

  MemoryCandidate? _buildEpisode(
    dynamic raw,
    List<ChunkRecord> chunks,
    String recordingDate,
  ) {
    final base = _commonFields(raw);
    if (base == null) return null;
    if (raw is! Map) return null;
    final occurred = _parseDate(raw['occurred_at']) ?? _parseDate(recordingDate);
    if (occurred == null) return null;
    return MemoryCandidate(
      kind: MemoryKind.episode,
      title: base.title,
      content: base.content,
      confidence: base.confidence,
      sourceChunkIds: _resolveSourceChunks(base.content, chunks),
      entityNames: base.entityNames,
      occurredAt: occurred,
    );
  }

  MemoryCandidate? _buildGoal(dynamic raw, List<ChunkRecord> chunks) {
    final base = _commonFields(raw);
    if (base == null) return null;
    if (raw is! Map) return null;
    final state = _parseGoalState(raw['state']);
    if (state == null) return null;
    return MemoryCandidate(
      kind: MemoryKind.goal,
      title: base.title,
      content: base.content,
      confidence: base.confidence,
      sourceChunkIds: _resolveSourceChunks(base.content, chunks),
      entityNames: base.entityNames,
      goalState: state,
      dueAt: _parseDate(raw['due_at']),
    );
  }

  static _CommonFields? _commonFields(dynamic raw) {
    if (raw is! Map) return null;
    final title = raw['title'];
    final content = raw['content'];
    final confRaw = raw['confidence'];
    if (title is! String || title.trim().isEmpty) return null;
    if (content is! String || content.trim().isEmpty) return null;
    final confidence = confRaw is num ? confRaw.toDouble() : null;
    if (confidence == null) return null;
    if (confidence < kMemoryExtractionMinConfidence) return null;
    if (confidence > 1.0) return null;
    final entityNames = <String>[];
    final rawEntities = raw['entity_names'];
    if (rawEntities is List) {
      for (final e in rawEntities) {
        if (e is String && e.trim().isNotEmpty) entityNames.add(e);
      }
    }
    return _CommonFields(
      title: title.trim(),
      content: content.trim(),
      confidence: confidence,
      entityNames: entityNames,
    );
  }

  static DateTime? _parseDate(Object? raw) {
    if (raw is! String) return null;
    // Accept YYYY-MM-DD strictly; anything else falls back to null.
    final match = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(raw);
    if (match == null) return null;
    final y = int.parse(match.group(1)!);
    final m = int.parse(match.group(2)!);
    final d = int.parse(match.group(3)!);
    if (m < 1 || m > 12) return null;
    if (d < 1 || d > 31) return null;
    return DateTime(y, m, d);
  }

  static GoalState? _parseGoalState(Object? raw) => switch (raw) {
        'open' => GoalState.open,
        'in_progress' => GoalState.inProgress,
        'done' => GoalState.done,
        'abandoned' => GoalState.abandoned,
        _ => null,
      };

  /// Attach chunk ids to a candidate by text overlap. We use a simple
  /// bag-of-words Jaccard — good enough to catch the "this memory
  /// came from chunk #3" signal for provenance, and fast enough to run
  /// per-candidate without burning an LLM call.
  static List<int> _resolveSourceChunks(
    String content,
    List<ChunkRecord> chunks,
  ) {
    final needle = _tokens(content);
    if (needle.isEmpty) return const <int>[];
    final scored = <({int id, double score})>[];
    for (final c in chunks) {
      final hay = _tokens(c.text);
      if (hay.isEmpty) continue;
      final inter = needle.intersection(hay).length;
      if (inter == 0) continue;
      final union = needle.union(hay).length;
      final score = inter / union;
      scored.add((id: c.id, score: score));
    }
    scored.sort((a, b) => b.score.compareTo(a.score));
    // Keep the top chunks that cleared a modest overlap bar. Matches
    // the "content-bearing" signal the extractor uses, without
    // dragging in weakly-related chunks.
    const minScore = 0.08;
    final out = <int>[];
    for (final s in scored) {
      if (s.score < minScore) break;
      out.add(s.id);
      if (out.length >= 3) break; // cap — memory provenance is tight
    }
    return out;
  }

  static Set<String> _tokens(String s) {
    final clean = s.toLowerCase().replaceAll(RegExp(r'[^\w\s]'), ' ');
    return clean
        .split(RegExp(r'\s+'))
        .where((w) => w.length > 2)
        .toSet();
  }

  static String _formatEntities(List<Entity> entities) {
    if (entities.isEmpty) return '(none)';
    return entities
        .map((e) => '- ${e.name} (${e.kind})')
        .join('\n');
  }

  static String _formatYmd(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
}

/// Internal bundle so each kind-specific builder shares validation.
final class _CommonFields {
  const _CommonFields({
    required this.title,
    required this.content,
    required this.confidence,
    required this.entityNames,
  });
  final String title;
  final String content;
  final double confidence;
  final List<String> entityNames;
}
