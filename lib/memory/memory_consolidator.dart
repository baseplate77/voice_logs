import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/drift.dart';

import '../core/errors.dart';
import '../core/logger.dart';
import '../core/result.dart';
import '../embed/embedder.dart';
import '../llm/llm_runner.dart';
import '../store/app_database.dart';
import 'memory_repository.dart';
import 'memory_vector_index.dart';
import 'models/consolidation_result.dart';
import 'models/memory.dart';
import 'models/memory_candidate.dart';
import 'prompts/consolidation_judge.dart';

/// Number of nearest neighbours the prefilter considers per candidate.
const int kConsolidationNeighbourLimit = 5;

/// Temperature for the judge. Low — classification, not generation.
const double kConsolidationJudgeTemperature = 0.1;

/// Consolidate [MemoryCandidate]s against the existing memory store.
///
/// For each candidate:
///   1. Embed title + content.
///   2. Cosine-search the vector index for the top-K neighbours of the
///      *same kind*.
///   3. For each neighbour past the [kConsolidationMergeThreshold]
///      prefilter, ask the LLM judge to classify the relationship.
///   4. Apply the verdict:
///      - `duplicate` → merge into the neighbour (union sources, bump
///        confidence, keep the older `createdAt`).
///      - `contradiction` → insert new, mark neighbour superseded.
///      - `unrelated` → continue to next neighbour.
///   5. If no verdict triggered, insert as a new memory.
class MemoryConsolidator {
  MemoryConsolidator({
    required this.repository,
    required this.embedder,
    required this.vectorIndex,
    required this.judgeRunner,
    required this.entityResolver,
    AppLogger? logger,
    DateTime Function()? clock,
  })  : _logger = logger ?? AppLogger(),
        _now = clock ?? DateTime.now;

  final MemoryRepository repository;
  final Embedder embedder;
  final MemoryVectorIndex vectorIndex;
  final LlmRunner judgeRunner;

  /// Resolves canonical entity names → Drift `entities.id`. Injected
  /// so tests can hand-roll the mapping without a DB join.
  final Future<Map<String, int>> Function(List<String> names) entityResolver;

  final AppLogger _logger;
  final DateTime Function() _now;

  /// Run the full consolidation pass.
  Future<Result<ConsolidationResult, AppError>> consolidate(
    List<MemoryCandidate> candidates,
  ) async {
    if (candidates.isEmpty) {
      return const Ok<ConsolidationResult, AppError>(
        ConsolidationResult(
          created: <Memory>[],
          merged: <Memory>[],
          superseded: <SupersededPair>[],
          dropped: <String>[],
        ),
      );
    }

    try {
      final created = <Memory>[];
      final merged = <Memory>[];
      final superseded = <SupersededPair>[];
      final dropped = <String>[];

      // Resolve entity names in one batch for the whole group —
      // cheaper than one lookup per candidate.
      final allNames = <String>{
        for (final c in candidates) ...c.entityNames,
      }.toList(growable: false);
      final nameToEntityId = allNames.isEmpty
          ? const <String, int>{}
          : await entityResolver(allNames);

      for (final candidate in candidates) {
        final embedResult = await _embedCandidate(candidate);
        if (embedResult.isErr) {
          _logger.warn(
            'MemoryConsolidator: embed failed for "${candidate.title}" — '
            'dropping',
          );
          dropped.add(candidate.title);
          continue;
        }
        final embedding = embedResult.okOrNull!;

        // Prefilter: ask the index for closest neighbours of any kind;
        // we'll restrict to same-kind in the judge step because the
        // vector store is unkind-aware (one box for all memories).
        final neighbours = vectorIndex.nearest(
          embedding,
          kConsolidationNeighbourLimit,
        );

        final action = await _classify(
          candidate: candidate,
          neighbours: neighbours,
        );

        final resolvedEntityIds = <int>[
          for (final n in candidate.entityNames)
            if (nameToEntityId[n.toLowerCase()] != null)
              nameToEntityId[n.toLowerCase()]!,
        ];

        switch (action) {
          case _InsertAction():
            final mem = _buildMemory(
              candidate: candidate,
              entityIds: resolvedEntityIds,
            );
            if (mem == null) {
              dropped.add(candidate.title);
              continue;
            }
            final saveR =
                await repository.save(mem, embedding: embedding);
            if (saveR.isErr) {
              dropped.add(candidate.title);
              continue;
            }
            created.add(saveR.okOrNull!);
          case _MergeAction(:final existingId):
            final updated = await _merge(
              existingId: existingId,
              candidate: candidate,
              embedding: embedding,
              resolvedEntityIds: resolvedEntityIds,
            );
            if (updated == null) {
              dropped.add(candidate.title);
            } else {
              merged.add(updated);
            }
          case _SupersedeAction(:final existingId):
            final mem = _buildMemory(
              candidate: candidate,
              entityIds: resolvedEntityIds,
            );
            if (mem == null) {
              dropped.add(candidate.title);
              continue;
            }
            final saveR =
                await repository.save(mem, embedding: embedding);
            if (saveR.isErr) {
              dropped.add(candidate.title);
              continue;
            }
            final replacement = saveR.okOrNull!;
            final superR = await repository.supersede(
              old: existingId,
              replacement: replacement.id,
              now: _now(),
            );
            if (superR.isErr) {
              dropped.add(candidate.title);
              continue;
            }
            // Re-read after supersede so the captured `old` reflects
            // its new superseded status for downstream callers.
            final oldR = await repository.get(existingId);
            if (oldR.isErr || oldR.okOrNull == null) {
              dropped.add(candidate.title);
              continue;
            }
            superseded.add(
              SupersededPair(
                old: oldR.okOrNull!,
                replacement: replacement,
              ),
            );
        }
      }

      return Ok<ConsolidationResult, AppError>(
        ConsolidationResult(
          created: List<Memory>.unmodifiable(created),
          merged: List<Memory>.unmodifiable(merged),
          superseded: List<SupersededPair>.unmodifiable(superseded),
          dropped: List<String>.unmodifiable(dropped),
        ),
      );
    } on Object catch (e, st) {
      _logger.error('consolidate failed', error: e, stackTrace: st);
      return Err<ConsolidationResult, AppError>(
        UnknownError('consolidate failed', cause: e, stackTrace: st),
      );
    }
  }

  Future<Result<Float32List, AppError>> _embedCandidate(
    MemoryCandidate c,
  ) async {
    // Embed title+content as a passage (stored, searched). The E5
    // convention is passage for stored vectors, query for incoming
    // queries — matches what chunk vectors use.
    final text = '${c.title}\n\n${c.content}';
    final r = await embedder.embedPassages(<String>[text]);
    if (r.isErr) return Err<Float32List, AppError>(r.errOrNull!);
    final vectors = r.okOrNull!;
    if (vectors.isEmpty) {
      return const Err<Float32List, AppError>(
        UnknownError('embedder returned no vectors'),
      );
    }
    return Ok<Float32List, AppError>(vectors.first);
  }

  Future<_Action> _classify({
    required MemoryCandidate candidate,
    required List<MemoryVectorMatch> neighbours,
  }) async {
    if (neighbours.isEmpty) return const _InsertAction();

    for (final n in neighbours) {
      // ObjectBox cosine: 1 - cos_sim. Merge threshold is a cosine
      // similarity, so convert.
      final sim = 1.0 - n.score;
      if (sim < kConsolidationMergeThreshold) {
        // Neighbours are distance-ordered; once we cross the
        // threshold, everything further is even less similar.
        break;
      }
      final existingR =
          await repository.get(MemoryId(n.memoryId));
      if (existingR.isErr) continue;
      final existing = existingR.okOrNull;
      if (existing == null) continue;
      if (existing.kind != candidate.kind) continue;
      if (existing.status != MemoryStatus.active) continue;

      final verdict = await _askJudge(
        existing: existing,
        candidate: candidate,
      );
      switch (verdict) {
        case _Verdict.duplicate:
          return _MergeAction(existingId: existing.id);
        case _Verdict.contradiction:
          return _SupersedeAction(existingId: existing.id);
        case _Verdict.unrelated:
          continue;
        case _Verdict.unknown:
          // Treat judge failures as "unrelated" — better to have a
          // duplicate row than to merge/supersede blindly.
          continue;
      }
    }
    return const _InsertAction();
  }

  Future<_Verdict> _askJudge({
    required Memory existing,
    required MemoryCandidate candidate,
  }) async {
    final prompt = consolidationJudgeTemplate.render(<String, String>{
      'existing_kind': existing.kind.name,
      'existing_title': existing.title,
      'existing_content': existing.content,
      'new_kind': candidate.kind.name,
      'new_title': candidate.title,
      'new_content': candidate.content,
    });
    final r = await judgeRunner.generateSync(
      prompt,
      temperatureOverride: kConsolidationJudgeTemperature,
    );
    if (r.isErr) return _Verdict.unknown;
    return _parseVerdict(r.okOrNull!);
  }

  static _Verdict _parseVerdict(String raw) {
    final stripped = _stripCodeFences(raw);
    try {
      final decoded = jsonDecode(stripped);
      if (decoded is! Map) return _Verdict.unknown;
      final verdict = decoded['verdict'];
      return switch (verdict) {
        'duplicate' => _Verdict.duplicate,
        'contradiction' => _Verdict.contradiction,
        'unrelated' => _Verdict.unrelated,
        _ => _Verdict.unknown,
      };
    } on FormatException {
      return _Verdict.unknown;
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

  Memory? _buildMemory({
    required MemoryCandidate candidate,
    required List<int> entityIds,
  }) {
    final id = repository.newId();
    final now = _now();
    switch (candidate.kind) {
      case MemoryKind.fact:
        return FactMemory(
          id: id,
          title: candidate.title,
          content: candidate.content,
          status: MemoryStatus.active,
          confidence: candidate.confidence,
          createdAt: now,
          updatedAt: now,
          sourceChunkIds: candidate.sourceChunkIds,
          entityIds: entityIds,
        );
      case MemoryKind.decision:
        final occurred = candidate.occurredAt ?? now;
        return DecisionMemory(
          id: id,
          title: candidate.title,
          content: candidate.content,
          status: MemoryStatus.active,
          confidence: candidate.confidence,
          createdAt: now,
          updatedAt: now,
          sourceChunkIds: candidate.sourceChunkIds,
          entityIds: entityIds,
          occurredAt: occurred,
        );
      case MemoryKind.episode:
        if (candidate.occurredAt == null) return null;
        return EpisodeMemory(
          id: id,
          title: candidate.title,
          content: candidate.content,
          status: MemoryStatus.active,
          confidence: candidate.confidence,
          createdAt: now,
          updatedAt: now,
          sourceChunkIds: candidate.sourceChunkIds,
          entityIds: entityIds,
          occurredAt: candidate.occurredAt!,
        );
      case MemoryKind.goal:
        final state = candidate.goalState;
        if (state == null) return null;
        return GoalMemory(
          id: id,
          title: candidate.title,
          content: candidate.content,
          status: MemoryStatus.active,
          confidence: candidate.confidence,
          createdAt: now,
          updatedAt: now,
          sourceChunkIds: candidate.sourceChunkIds,
          entityIds: entityIds,
          dueAt: candidate.dueAt,
          state: state,
        );
    }
  }

  Future<Memory?> _merge({
    required MemoryId existingId,
    required MemoryCandidate candidate,
    required Float32List embedding,
    required List<int> resolvedEntityIds,
  }) async {
    final existingR = await repository.get(existingId);
    if (existingR.isErr) return null;
    final existing = existingR.okOrNull;
    if (existing == null) return null;

    // Merge strategy: union source chunks + entity ids; bump
    // confidence by a conservative factor (capped at 1.0); keep the
    // older createdAt so the memory retains its historical ordering;
    // update text only if the candidate's content is strictly longer
    // (richer phrasing tends to come from later, more detailed
    // mentions).
    final mergedChunks = <int>{
      ...existing.sourceChunkIds,
      ...candidate.sourceChunkIds,
    }.toList(growable: false);
    final mergedEntityIds = <int>{
      ...existing.entityIds,
      ...resolvedEntityIds,
    }.toList(growable: false);
    final newContent = candidate.content.length > existing.content.length
        ? candidate.content
        : existing.content;
    final bumped =
        (existing.confidence + 0.05).clamp(0.0, 1.0).toDouble();
    final now = _now();

    final updated = _withUpdates(
      existing,
      content: newContent,
      sourceChunkIds: mergedChunks,
      entityIds: mergedEntityIds,
      confidence: bumped,
      updatedAt: now,
    );
    final r = await repository.update(
      updated,
      embedding: newContent == existing.content ? null : embedding,
    );
    if (r.isErr) return null;
    return r.okOrNull;
  }

  /// Produce a same-kind `Memory` with selected fields replaced.
  /// Single switch to keep the sealed hierarchy closed.
  static Memory _withUpdates(
    Memory m, {
    required String content,
    required List<int> sourceChunkIds,
    required List<int> entityIds,
    required double confidence,
    required DateTime updatedAt,
  }) {
    switch (m) {
      case FactMemory():
        return FactMemory(
          id: m.id,
          title: m.title,
          content: content,
          status: m.status,
          confidence: confidence,
          createdAt: m.createdAt,
          updatedAt: updatedAt,
          supersededById: m.supersededById,
          sourceChunkIds: sourceChunkIds,
          entityIds: entityIds,
        );
      case DecisionMemory():
        return DecisionMemory(
          id: m.id,
          title: m.title,
          content: content,
          status: m.status,
          confidence: confidence,
          createdAt: m.createdAt,
          updatedAt: updatedAt,
          supersededById: m.supersededById,
          sourceChunkIds: sourceChunkIds,
          entityIds: entityIds,
          occurredAt: m.occurredAt,
        );
      case EpisodeMemory():
        return EpisodeMemory(
          id: m.id,
          title: m.title,
          content: content,
          status: m.status,
          confidence: confidence,
          createdAt: m.createdAt,
          updatedAt: updatedAt,
          supersededById: m.supersededById,
          sourceChunkIds: sourceChunkIds,
          entityIds: entityIds,
          occurredAt: m.occurredAt,
        );
      case GoalMemory():
        return GoalMemory(
          id: m.id,
          title: m.title,
          content: content,
          status: m.status,
          confidence: confidence,
          createdAt: m.createdAt,
          updatedAt: updatedAt,
          supersededById: m.supersededById,
          sourceChunkIds: sourceChunkIds,
          entityIds: entityIds,
          dueAt: m.dueAt,
          state: m.state,
        );
    }
  }
}

/// A Drift-backed resolver: look up each name in `entities.canonical_name`
/// case-insensitively and return the map of matched name → id. Names
/// without matches are absent.
Future<Map<String, int>> resolveEntitiesByName(
  AppDatabase db,
  List<String> names,
) async {
  if (names.isEmpty) return const <String, int>{};
  final lower = names.map((n) => n.toLowerCase()).toList(growable: false);
  final rows = await (db.select(db.entities)
        ..where((e) => e.canonicalName.lower().isIn(lower)))
      .get();
  final out = <String, int>{};
  for (final row in rows) {
    out[row.canonicalName.toLowerCase()] = row.id;
  }
  return out;
}

enum _Verdict { duplicate, contradiction, unrelated, unknown }

sealed class _Action {
  const _Action();
}

final class _InsertAction extends _Action {
  const _InsertAction();
}

final class _MergeAction extends _Action {
  const _MergeAction({required this.existingId});
  final MemoryId existingId;
}

final class _SupersedeAction extends _Action {
  const _SupersedeAction({required this.existingId});
  final MemoryId existingId;
}
