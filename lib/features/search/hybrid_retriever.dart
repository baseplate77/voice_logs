import 'package:drift/drift.dart';

import '../../core/app_error.dart';
import '../../core/db/database.dart';
import '../../core/result.dart';
import 'embedder.dart';
import 'rrf.dart';
import 'vec_store.dart';

/// A retrieved voice log with the score fused across retrieval paths.
class SearchHit {
  const SearchHit({
    required this.logId,
    required this.fusedScore,
    required this.matchedVia,
    required this.snippet,
  });

  final String logId;
  final double fusedScore;

  /// Which paths the log matched on. One log can match on multiple.
  final Set<MatchSource> matchedVia;

  /// Short preview text, usually the top-ranked segment or the first
  /// line of the transcript.
  final String snippet;
}

enum MatchSource { fts, vector, entity }

sealed class RetrieverError extends AppError {
  const RetrieverError({required super.message, super.cause, super.stack});
}

final class RetrieverDbError extends RetrieverError {
  const RetrieverDbError({required super.message, super.cause, super.stack});
}

final class RetrieverEmbedError extends RetrieverError {
  const RetrieverEmbedError({required super.message, super.cause, super.stack});
}

/// Merges FTS5, vector, and entity-boost paths via reciprocal rank
/// fusion. Entity boost is stubbed in Phase 3 — it arrives in Phase 5
/// when the canonicalizer is wired.
class HybridRetriever {
  HybridRetriever({
    required VoxSynthDatabase db,
    required Embedder embedder,
    required VecStore vecStore,
    int ftsLimit = 20,
    int vectorLimit = 20,
    int rrfK = 60,
  }) : _db = db,
       _embedder = embedder,
       _vecStore = vecStore,
       _ftsLimit = ftsLimit,
       _vectorLimit = vectorLimit,
       _rrfK = rrfK;

  final VoxSynthDatabase _db;
  final Embedder _embedder;
  final VecStore _vecStore;
  final int _ftsLimit;
  final int _vectorLimit;
  final int _rrfK;

  Future<Result<List<SearchHit>, RetrieverError>> search(
    String query, {
    int limit = 10,
  }) async {
    if (query.trim().isEmpty) return const Ok([]);

    // FTS path — raw_transcript + cleaned_text, so refinement isn't a
    // pre-req for finding something you just said.
    List<String> ftsLogIds;
    try {
      ftsLogIds = await _ftsSearch(query);
    } on Object catch (e, s) {
      return Err(
        RetrieverDbError(message: 'FTS search failed: $e', cause: e, stack: s),
      );
    }

    // Vector path — embed the query with `"query: "` prefix.
    List<String> vectorLogIds = const [];
    final Map<String, String> vectorSnippets = {};
    final embedded = await _embedder.embedQuery(query);
    switch (embedded) {
      case Ok(:final value):
        final hits = _vecStore.search(value.vector, k: _vectorLimit);
        final seen = <String>{};
        for (final hit in hits) {
          if (seen.add(hit.logId)) {
            vectorSnippets[hit.logId] = hit.text;
          }
        }
        vectorLogIds = seen.toList();
      case Err(:final error):
        return Err(
          RetrieverEmbedError(
            message: 'Query embedding failed: ${error.message}',
            cause: error.cause,
            stack: error.stack,
          ),
        );
    }

    // Entity boost is a no-op until Phase 5 wires the canonicalizer.
    const entityLogIds = <String>[];

    final fused = reciprocalRankFusion(
      rankedLists: [ftsLogIds, vectorLogIds, entityLogIds],
      k: _rrfK,
    );
    final ordered = sortByScoreDescending(fused).take(limit).toList();

    final snippets = await _snippetsFor(ordered);

    return Ok(
      ordered.map((id) {
        final matched = <MatchSource>{};
        if (ftsLogIds.contains(id)) matched.add(MatchSource.fts);
        if (vectorLogIds.contains(id)) matched.add(MatchSource.vector);
        return SearchHit(
          logId: id,
          fusedScore: fused[id] ?? 0,
          matchedVia: matched,
          snippet: vectorSnippets[id] ?? snippets[id] ?? '',
        );
      }).toList(),
    );
  }

  Future<List<String>> _ftsSearch(String query) async {
    // sqlite's FTS5 MATCH takes a bare query — very tolerant of user
    // input. The FTS table is content-less so we rely on rowid alone
    // here, not joining to voice_logs.
    final escaped = query.replaceAll('"', '""');
    final rows = await _db
        .customSelect(
          'SELECT rowid FROM voice_logs_fts WHERE voice_logs_fts '
          'MATCH ? ORDER BY rank LIMIT ?',
          variables: [Variable<String>('"$escaped"'), Variable<int>(_ftsLimit)],
        )
        .get();

    // The FTS rowid maps to voice_logs.rowid which is internal — fetch
    // the corresponding ids. In Phase 3 we sync on insert so the two
    // rowids are aligned; Phase 2 hadn't wired FTS sync yet and the
    // embed job is the first thing to populate the index.
    final rowIds = rows.map((r) => r.read<int>('rowid')).toList();
    if (rowIds.isEmpty) return const [];
    final logs = await _db
        .customSelect(
          'SELECT id FROM voice_logs WHERE rowid IN '
          '(${List.filled(rowIds.length, '?').join(',')})',
          variables: rowIds.map(Variable<int>.new).toList(),
        )
        .get();
    return logs.map((r) => r.read<String>('id')).toList();
  }

  Future<Map<String, String>> _snippetsFor(List<String> logIds) async {
    if (logIds.isEmpty) return {};
    final rows = await (_db.select(
      _db.voiceLogs,
    )..where((t) => t.id.isIn(logIds))).get();
    return {for (final r in rows) r.id: r.cleanedText ?? r.rawTranscript};
  }
}
