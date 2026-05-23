import 'dart:typed_data';

import 'package:drift/drift.dart';

import '../../core/app_error.dart';
import '../../core/db/database.dart';
import '../../core/db/repositories/memory_repository.dart';
import '../../core/result.dart';
import '../search/embedder.dart';
import '../search/embedding_math.dart';
import '../search/natural_language_query.dart';
import '../search/rrf.dart';
import 'memory_types.dart';

/// Errors from local memory retrieval.
sealed class MemoryRetrieverError extends AppError {
  const MemoryRetrieverError({
    required super.message,
    super.cause,
    super.stack,
  });
}

/// Drift/SQLite retrieval failure.
final class MemoryRetrieverDbError extends MemoryRetrieverError {
  const MemoryRetrieverDbError({
    required super.message,
    super.cause,
    super.stack,
  });
}

/// Local e5 query embedding failed.
final class MemoryRetrieverEmbedError extends MemoryRetrieverError {
  const MemoryRetrieverEmbedError({
    required super.message,
    super.cause,
    super.stack,
  });
}

/// Hybrid local memory retriever over FTS, vector similarity, and entity links.
class MemoryRetriever {
  MemoryRetriever({
    required VoxSynthDatabase db,
    required MemoryRepository repository,
    required Embedder embedder,
    int ftsLimit = 20,
    int vectorLimit = 20,
    int entityLimit = 20,
    int rrfK = 60,
    DateTime Function()? now,
  }) : _db = db,
       _repository = repository,
       _embedder = embedder,
       _ftsLimit = ftsLimit,
       _vectorLimit = vectorLimit,
       _entityLimit = entityLimit,
       _rrfK = rrfK,
       _now = now ?? DateTime.now;

  final VoxSynthDatabase _db;
  final MemoryRepository _repository;
  final Embedder _embedder;
  final int _ftsLimit;
  final int _vectorLimit;
  final int _entityLimit;
  final int _rrfK;
  final DateTime Function() _now;

  /// Retrieve active, non-sensitive-unconfirmed memory cards for [query].
  Future<Result<List<MemoryHit>, MemoryRetrieverError>> search(
    String query, {
    int limit = 10,
  }) async {
    if (query.trim().isEmpty) return const Ok([]);
    final parsed = NaturalLanguageSearchQuery.parse(query, now: _now());

    List<String> ftsIds;
    List<String> entityIds;
    List<String> typeIds;
    List<String> dateIds;
    try {
      ftsIds = await _ftsSearch(parsed.lexicalTerms);
      entityIds = await _entitySearch(parsed);
      typeIds = await _typeSearch(parsed);
      dateIds = await _dateSearch(parsed);
    } on Object catch (e, s) {
      return Err(
        MemoryRetrieverDbError(
          message: 'Memory retrieval DB search failed: $e',
          cause: e,
          stack: s,
        ),
      );
    }

    var vectorIds = const <String>[];
    final embedded = await _embedder.embedQuery(parsed.semanticQuery);
    switch (embedded) {
      case Ok(:final value):
        vectorIds = await _vectorSearch(value.vector);
      case Err():
        vectorIds = const [];
    }

    final fused = reciprocalRankFusion(
      rankedLists: [ftsIds, vectorIds, entityIds, typeIds, dateIds],
      k: _rrfK,
    );
    final ordered = sortByScoreDescending(fused).take(limit).toList();
    final hits = <MemoryHit>[];
    for (final id in ordered) {
      final memory = await _repository.find(id);
      if (memory == null || memory.status != MemoryStatus.active) continue;
      final matched = <MemoryMatchSource>{};
      if (ftsIds.contains(id)) matched.add(MemoryMatchSource.fts);
      if (vectorIds.contains(id)) matched.add(MemoryMatchSource.vector);
      if (entityIds.contains(id)) matched.add(MemoryMatchSource.entity);
      if (typeIds.contains(id)) matched.add(MemoryMatchSource.type);
      if (dateIds.contains(id)) matched.add(MemoryMatchSource.date);
      hits.add(
        MemoryHit(
          memory: memory,
          fusedScore: _boostedScore(fused[id] ?? 0, memory),
          matchedVia: matched,
        ),
      );
    }
    hits.sort((a, b) => b.fusedScore.compareTo(a.fusedScore));
    return Ok(hits);
  }

  Future<List<String>> _ftsSearch(List<String> terms) async {
    final ftsQuery = _buildFtsQuery(terms);
    if (ftsQuery.isEmpty) return const [];
    final rows = await _db
        .customSelect(
          'SELECT mi.id FROM memory_items_fts fts '
          'JOIN memory_items mi ON mi.rowid = fts.rowid '
          'WHERE memory_items_fts MATCH ? '
          'AND mi.status = ? '
          'ORDER BY rank LIMIT ?',
          variables: [
            Variable<String>(ftsQuery),
            Variable<String>(MemoryStatus.active.wire),
            Variable<int>(_ftsLimit),
          ],
          readsFrom: {_db.memoryItems},
        )
        .get();
    return rows.map((r) => r.read<String>('id')).toList();
  }

  static String _buildFtsQuery(List<String> terms) {
    if (terms.isEmpty) return '';
    return terms.map((t) => '${t.replaceAll('"', '""')}*').join(' ');
  }

  Future<List<String>> _vectorSearch(Float32List queryVector) async {
    final memories = await _repository.activeWithEmbeddings();
    final scored = <({String id, double score})>[];
    for (final memory in memories) {
      final embedding = memory.embedding;
      if (embedding == null || embedding.length != queryVector.length) continue;
      scored.add((
        id: memory.id,
        score: cosineSimilarity(embedding, queryVector),
      ));
    }
    scored.sort((a, b) => b.score.compareTo(a.score));
    return scored.take(_vectorLimit).map((s) => s.id).toList();
  }

  Future<List<String>> _entitySearch(NaturalLanguageSearchQuery query) async {
    final rows = await _db
        .customSelect(
          'SELECT DISTINCT mel.memory_id, ce.display_name FROM canonical_entities ce '
          'JOIN memory_entity_links mel ON mel.canonical_entity_id = ce.id '
          'JOIN memory_items mi ON mi.id = mel.memory_id '
          'WHERE mi.status = ? '
          'ORDER BY mi.updated_at DESC LIMIT ?',
          variables: [
            Variable<String>(MemoryStatus.active.wire),
            Variable<int>(_entityLimit),
          ],
          readsFrom: {
            _db.canonicalEntities,
            _db.memoryEntityLinks,
            _db.memoryItems,
          },
        )
        .get();
    final matched = <String>[];
    for (final row in rows) {
      final memoryId = row.read<String>('memory_id');
      final entityName = row.read<String>('display_name');
      if (query.containsEntityName(entityName) && !matched.contains(memoryId)) {
        matched.add(memoryId);
      }
    }
    return matched;
  }

  Future<List<String>> _typeSearch(NaturalLanguageSearchQuery query) async {
    final matchedTypes = <String>{};
    for (final term in query.lexicalTerms) {
      for (final type in MemoryType.values) {
        if (term == type.wire || term == '${type.wire}s') {
          matchedTypes.add(type.wire);
        }
      }
    }
    if (matchedTypes.isEmpty) return const [];
    final rows =
        await (_db.select(_db.memoryItems)
              ..where(
                (t) =>
                    t.status.equals(MemoryStatus.active.wire) &
                    t.type.isIn(matchedTypes),
              )
              ..orderBy([(t) => OrderingTerm.desc(t.updatedAt)]))
            .get();
    return rows.map((r) => r.id).take(_entityLimit).toList(growable: false);
  }

  Future<List<String>> _dateSearch(NaturalLanguageSearchQuery query) async {
    final range = query.dateRange;
    if (range == null) return const [];
    final rows =
        await (_db.select(_db.memoryItems)
              ..where((t) {
                var expression = t.status.equals(MemoryStatus.active.wire);
                final start = range.start;
                if (start != null) {
                  expression =
                      expression &
                      t.lastSeenAt.isBiggerOrEqualValue(
                        start.millisecondsSinceEpoch,
                      );
                }
                final end = range.end;
                if (end != null) {
                  expression =
                      expression &
                      t.lastSeenAt.isSmallerOrEqualValue(
                        end.millisecondsSinceEpoch,
                      );
                }
                return expression;
              })
              ..orderBy([(t) => OrderingTerm.desc(t.lastSeenAt)]))
            .get();
    return rows.map((r) => r.id).take(_entityLimit).toList(growable: false);
  }

  double _boostedScore(double base, MemoryItemView memory) {
    final confidenceBoost = memory.confidence * 0.001;
    final recencyDays = _now().difference(memory.lastSeenAt).inDays;
    final recencyBoost = recencyDays <= 7 ? 0.001 : 0.0;
    return base + confidenceBoost + recencyBoost;
  }
}
