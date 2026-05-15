import 'package:drift/drift.dart';

import '../../core/app_error.dart';
import '../../core/db/database.dart';
import '../../core/result.dart';
import 'embedder.dart';
import 'rrf.dart';
import 'search_filters.dart';
import 'vec_store.dart';

/// A retrieved voice log with the score fused across retrieval paths.
class SearchHit {
  const SearchHit({
    required this.logId,
    required this.fusedScore,
    required this.matchedVia,
    required this.snippet,
    this.segments = const [],
    this.fullText,
    this.createdAt,
    this.logTitle,
    this.bestSegmentId,
    this.bestSegmentStartMs,
    this.bestSegmentEndMs,
    this.localReason = '',
    this.matchedEntityNames = const [],
  });

  final String logId;
  final double fusedScore;

  /// Which paths the log matched on. One log can match on multiple.
  final Set<MatchSource> matchedVia;

  /// Short preview text, usually the top-ranked segment or the first
  /// line of the transcript.
  final String snippet;

  /// All matching vector segments for this log, in hit order.
  final List<String> segments;

  /// Full cleaned transcript (or raw). Available for short-log inclusion.
  final String? fullText;

  /// When the voice log was recorded, for temporal context in prompts.
  final DateTime? createdAt;

  /// Short Gemma-generated log title, if available.
  final String? logTitle;

  /// `transcript_segments.id` of the segment that best represents *why*
  /// this log matched — the segment containing the matched keyword, or
  /// the one whose text overlaps the top vector chunk. Null when the log
  /// has no transcript segments (legacy or text-only logs).
  final String? bestSegmentId;

  /// Audio offsets corresponding to [bestSegmentId]. Both null together.
  final int? bestSegmentStartMs;
  final int? bestSegmentEndMs;

  /// Cheap, locally-derived "why this matched" string for the UI. Empty
  /// when nothing more specific than the snippet can be said.
  final String localReason;

  /// Display names of canonical entities the log matched via the user's
  /// active facet filters. Used by the UI to render entity chips on the
  /// result tile.
  final List<String> matchedEntityNames;
}

enum MatchSource { fts, vector, entity }

class _LogMeta {
  const _LogMeta({
    required this.rawText,
    required this.cleanedText,
    required this.createdAt,
    required this.title,
  });

  final String rawText;
  final String? cleanedText;
  final DateTime createdAt;
  final String? title;

  String get displayText => cleanedText == null || cleanedText!.trim().isEmpty
      ? rawText
      : cleanedText!;

  Iterable<String> get excerptCandidates sync* {
    if (cleanedText != null && cleanedText!.trim().isNotEmpty) {
      yield cleanedText!;
    }
    yield rawText;
  }
}

class _SegMeta {
  const _SegMeta({
    required this.id,
    required this.startMs,
    required this.endMs,
    required this.text,
  });

  final String id;
  final int startMs;
  final int endMs;
  final String text;
}

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
/// fusion. The entity path doubles as a hard filter when the user has
/// selected facet chips: only logs satisfying every facet group survive
/// into the fused ranking.
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
    SearchFilters filters = const SearchFilters(),
  }) async {
    if (query.trim().isEmpty) return const Ok([]);

    // Resolve hard-filter constraints (entity facets, date, action items)
    // into the set of log IDs that survive. Null means "no constraint".
    Set<String>? eligible;
    Map<String, List<String>> matchedEntityNamesByLog = const {};
    try {
      final filterResult = await _resolveFilters(filters);
      eligible = filterResult.eligibleLogIds;
      matchedEntityNamesByLog = filterResult.matchedEntityNamesByLog;
    } on Object catch (e, s) {
      return Err(
        RetrieverDbError(
          message: 'Filter resolution failed: $e',
          cause: e,
          stack: s,
        ),
      );
    }
    if (eligible != null && eligible.isEmpty) return const Ok([]);

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
    if (eligible != null) {
      ftsLogIds = ftsLogIds.where(eligible.contains).toList();
    }

    // Vector path — embed the query with `"query: "` prefix.
    List<String> vectorLogIds = const [];
    final vectorSegments = <String, List<String>>{};
    final embedded = await _embedder.embedQuery(query);
    switch (embedded) {
      case Ok(:final value):
        final hits = _vecStore.search(value.vector, k: _vectorLimit);
        final seen = <String>{};
        for (final hit in hits) {
          if (eligible != null && !eligible.contains(hit.logId)) continue;
          vectorSegments.putIfAbsent(hit.logId, () => []).add(hit.text);
          seen.add(hit.logId);
        }
        vectorLogIds = seen.toList();
      case Err():
        vectorLogIds = const [];
    }

    // Entity-boost ranking signal — every log that survived the facet
    // intersection gets a rank slot regardless of FTS/vector hits. Drop
    // the names of any logs already filtered out by the AND across
    // facets so they neither rank nor render a chip.
    if (eligible != null) {
      matchedEntityNamesByLog = {
        for (final entry in matchedEntityNamesByLog.entries)
          if (eligible.contains(entry.key)) entry.key: entry.value,
      };
    }
    final entityLogIds = matchedEntityNamesByLog.keys.toList()
      ..sort((a, b) {
        final cmp = matchedEntityNamesByLog[b]!.length.compareTo(
          matchedEntityNamesByLog[a]!.length,
        );
        return cmp != 0 ? cmp : a.compareTo(b);
      });

    final fused = reciprocalRankFusion(
      rankedLists: [ftsLogIds, vectorLogIds, entityLogIds],
      k: _rrfK,
    );
    final ordered = sortByScoreDescending(fused).take(limit).toList();
    if (ordered.isEmpty) return const Ok([]);

    final logMeta = await _logMetaFor(ordered);
    final transcriptSegments = await _transcriptSegmentsFor(ordered);
    final queryTerms = _queryTerms(query);

    return Ok(
      ordered.map((id) {
        final matched = <MatchSource>{};
        final matchedFts = ftsLogIds.contains(id);
        if (matchedFts) matched.add(MatchSource.fts);
        if (vectorLogIds.contains(id)) matched.add(MatchSource.vector);
        if (matchedEntityNamesByLog.containsKey(id)) {
          matched.add(MatchSource.entity);
        }
        final meta = logMeta[id];
        final segs = vectorSegments[id] ?? const [];
        final keywordExcerpt = matchedFts && meta != null
            ? _excerptForTerms(meta.excerptCandidates, queryTerms)
            : null;
        final snippet =
            keywordExcerpt ??
            (segs.isNotEmpty ? segs.first : meta?.displayText ?? '');

        final segments = transcriptSegments[id] ?? const [];
        final pinpoint = _pinpointSegment(
          segments: segments,
          queryTerms: queryTerms,
          vectorChunks: segs,
          matchedFts: matchedFts,
        );

        final entityNames = matchedEntityNamesByLog[id] ?? const [];
        final reason = _localReason(
          matched: matched,
          entityNames: entityNames,
          pinpoint: pinpoint,
          queryTerms: queryTerms,
        );

        return SearchHit(
          logId: id,
          fusedScore: fused[id] ?? 0,
          matchedVia: matched,
          snippet: snippet,
          segments: segs,
          fullText: meta?.displayText,
          createdAt: meta?.createdAt,
          logTitle: meta?.title,
          bestSegmentId: pinpoint?.id,
          bestSegmentStartMs: pinpoint?.startMs,
          bestSegmentEndMs: pinpoint?.endMs,
          localReason: reason,
          matchedEntityNames: entityNames,
        );
      }).toList(),
    );
  }

  Future<List<String>> _ftsSearch(String query) async {
    final ftsQuery = _buildFtsQuery(query);
    if (ftsQuery.isEmpty) return const [];
    final rows = await _db
        .customSelect(
          'SELECT rowid FROM voice_logs_fts WHERE voice_logs_fts '
          'MATCH ? ORDER BY rank LIMIT ?',
          variables: [Variable<String>(ftsQuery), Variable<int>(_ftsLimit)],
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

  Future<Map<String, _LogMeta>> _logMetaFor(List<String> logIds) async {
    if (logIds.isEmpty) return {};
    final rows = await (_db.select(
      _db.voiceLogs,
    )..where((t) => t.id.isIn(logIds))).get();
    return {
      for (final r in rows)
        r.id: _LogMeta(
          rawText: r.rawTranscript,
          cleanedText: r.cleanedText,
          createdAt: DateTime.fromMillisecondsSinceEpoch(r.createdAt),
          title: r.title,
        ),
    };
  }

  Future<Map<String, List<_SegMeta>>> _transcriptSegmentsFor(
    List<String> logIds,
  ) async {
    if (logIds.isEmpty) return const {};
    final rows =
        await (_db.select(_db.transcriptSegments)
              ..where((t) => t.logId.isIn(logIds))
              ..orderBy([(t) => OrderingTerm.asc(t.startTimeMs)]))
            .get();
    final result = <String, List<_SegMeta>>{};
    for (final r in rows) {
      result
          .putIfAbsent(r.logId, () => [])
          .add(
            _SegMeta(
              id: r.id,
              startMs: r.startTimeMs,
              endMs: r.endTimeMs,
              text: r.segmentText,
            ),
          );
    }
    return result;
  }

  /// Pick the transcript segment that best represents why a log matched.
  /// Preference order:
  ///   1. A segment containing one of the query terms (FTS pinpoint).
  ///   2. A segment whose text overlaps the top vector chunk.
  ///   3. The first segment of the log (start of audio).
  /// Returns null only when the log has no transcript segments at all.
  static _SegMeta? _pinpointSegment({
    required List<_SegMeta> segments,
    required List<String> queryTerms,
    required List<String> vectorChunks,
    required bool matchedFts,
  }) {
    if (segments.isEmpty) return null;
    if (matchedFts && queryTerms.isNotEmpty) {
      for (final seg in segments) {
        final lower = seg.text.toLowerCase();
        for (final term in queryTerms) {
          if (lower.contains(term)) return seg;
        }
      }
    }
    if (vectorChunks.isNotEmpty) {
      // Match by a leading slice of the chunk — chunks are concatenated
      // segment text, so the first ~40 chars are almost always a
      // substring of exactly one transcript segment.
      final probe = vectorChunks.first
          .substring(0, vectorChunks.first.length.clamp(0, 40))
          .toLowerCase()
          .trim();
      if (probe.isNotEmpty) {
        for (final seg in segments) {
          if (seg.text.toLowerCase().contains(probe)) return seg;
        }
      }
    }
    return segments.first;
  }

  static String _localReason({
    required Set<MatchSource> matched,
    required List<String> entityNames,
    required _SegMeta? pinpoint,
    required List<String> queryTerms,
  }) {
    final parts = <String>[];
    if (entityNames.isNotEmpty) {
      final shown = entityNames.take(2).join(', ');
      final extra = entityNames.length > 2 ? ' +${entityNames.length - 2}' : '';
      parts.add('Mentions $shown$extra');
    }
    if (matched.contains(MatchSource.fts) && queryTerms.isNotEmpty) {
      final at = pinpoint != null ? ' at ${_formatMs(pinpoint.startMs)}' : '';
      parts.add('Keyword "${queryTerms.first}"$at');
    } else if (matched.contains(MatchSource.vector)) {
      final at = pinpoint != null ? ' at ${_formatMs(pinpoint.startMs)}' : '';
      parts.add('Semantically similar$at');
    }
    return parts.join(' · ');
  }

  static String _formatMs(int ms) {
    final totalSeconds = ms ~/ 1000;
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  Future<_FilterResolution> _resolveFilters(SearchFilters filters) async {
    if (filters.isEmpty) {
      return const _FilterResolution(
        eligibleLogIds: null,
        matchedEntityNamesByLog: {},
      );
    }

    Set<String>? running;
    final matchedNames = <String, List<String>>{};

    // Entity facet groups: AND across facets, OR within each facet.
    for (final entry in filters.entityIdsByFacet.entries) {
      final ids = entry.value;
      if (ids.isEmpty) continue;
      final mentions = await (_db.select(
        _db.entityMentions,
      )..where((t) => t.canonicalEntityId.isIn(ids))).get();
      if (mentions.isEmpty) {
        return const _FilterResolution(
          eligibleLogIds: <String>{},
          matchedEntityNamesByLog: {},
        );
      }
      final facetLogs = mentions.map((m) => m.logId).toSet();
      running = running == null ? facetLogs : running.intersection(facetLogs);
      if (running.isEmpty) {
        return const _FilterResolution(
          eligibleLogIds: <String>{},
          matchedEntityNamesByLog: {},
        );
      }
    }

    // Look up display names for the entity chips matched on each log.
    final allSelectedIds = filters.entityIdsByFacet.values
        .expand((s) => s)
        .toSet();
    if (allSelectedIds.isNotEmpty) {
      final entities = await (_db.select(
        _db.canonicalEntities,
      )..where((t) => t.id.isIn(allSelectedIds))).get();
      final nameById = {for (final e in entities) e.id: e.displayName};
      final mentions = await (_db.select(
        _db.entityMentions,
      )..where((t) => t.canonicalEntityId.isIn(allSelectedIds))).get();
      for (final m in mentions) {
        final name = nameById[m.canonicalEntityId];
        if (name == null) continue;
        final list = matchedNames.putIfAbsent(m.logId, () => <String>[]);
        if (!list.contains(name)) list.add(name);
      }
    }

    // Date range over voice_logs.createdAt (stored as epoch ms).
    final range = filters.dateRange;
    if (!range.isUnbounded) {
      final query = _db.select(_db.voiceLogs);
      if (range.start != null) {
        query.where(
          (t) => t.createdAt.isBiggerOrEqualValue(
            range.start!.millisecondsSinceEpoch,
          ),
        );
      }
      if (range.end != null) {
        query.where(
          (t) => t.createdAt.isSmallerOrEqualValue(
            range.end!.millisecondsSinceEpoch,
          ),
        );
      }
      final rows = await query.get();
      final dateLogs = rows.map((r) => r.id).toSet();
      running = running == null ? dateLogs : running.intersection(dateLogs);
      if (running.isEmpty) {
        return _FilterResolution(
          eligibleLogIds: const <String>{},
          matchedEntityNamesByLog: matchedNames,
        );
      }
    }

    // Action-items toggle: distinct log IDs that have at least one row.
    if (filters.requireActionItems) {
      final rows = await _db
          .customSelect('SELECT DISTINCT voice_log_id AS id FROM action_items')
          .get();
      final taskLogs = rows.map((r) => r.read<String>('id')).toSet();
      running = running == null ? taskLogs : running.intersection(taskLogs);
      if (running.isEmpty) {
        return _FilterResolution(
          eligibleLogIds: const <String>{},
          matchedEntityNamesByLog: matchedNames,
        );
      }
    }

    return _FilterResolution(
      eligibleLogIds: running,
      matchedEntityNamesByLog: matchedNames,
    );
  }

  static final _stopWords = {
    'i',
    'me',
    'my',
    'we',
    'our',
    'you',
    'your',
    'he',
    'she',
    'it',
    'they',
    'them',
    'a',
    'an',
    'the',
    'is',
    'am',
    'are',
    'was',
    'were',
    'be',
    'been',
    'being',
    'have',
    'has',
    'had',
    'do',
    'does',
    'did',
    'will',
    'would',
    'could',
    'should',
    'can',
    'may',
    'might',
    'at',
    'in',
    'on',
    'to',
    'for',
    'of',
    'with',
    'by',
    'from',
    'about',
    'that',
    'this',
    'what',
    'which',
    'who',
    'whom',
    'and',
    'or',
    'but',
    'not',
    'no',
    'if',
    'so',
    'than',
  };

  static List<String> _queryTerms(String query) {
    final seen = <String>{};
    return query
        .toLowerCase()
        .split(RegExp(r'\W+'))
        .where((w) => w.length > 1 && !_stopWords.contains(w))
        .where(seen.add)
        .toList();
  }

  static String _buildFtsQuery(String query) {
    final terms = _queryTerms(query);
    if (terms.isEmpty) return '';
    return terms.map((t) => '"${t.replaceAll('"', '""')}"').join(' ');
  }

  static String? _excerptForTerms(
    Iterable<String> texts,
    List<String> terms, {
    int leadingChars = 16,
    int trailingChars = 120,
  }) {
    if (terms.isEmpty) return null;
    for (final text in texts) {
      if (text.trim().isEmpty) continue;
      final lower = text.toLowerCase();
      int? bestStart;
      var bestLength = 0;
      for (final term in terms) {
        final start = lower.indexOf(term);
        if (start < 0) continue;
        if (bestStart == null || start < bestStart) {
          bestStart = start;
          bestLength = term.length;
        }
      }
      if (bestStart == null) continue;
      var excerptStart = (bestStart - leadingChars).clamp(0, text.length);
      var excerptEnd = (bestStart + bestLength + trailingChars).clamp(
        0,
        text.length,
      );
      while (excerptStart > 0 && !_isBreak(text.codeUnitAt(excerptStart - 1))) {
        excerptStart--;
      }
      while (excerptEnd < text.length &&
          !_isBreak(text.codeUnitAt(excerptEnd))) {
        excerptEnd++;
      }
      final prefix = excerptStart > 0 ? '…' : '';
      final suffix = excerptEnd < text.length ? '…' : '';
      return '$prefix${text.substring(excerptStart, excerptEnd).trim()}$suffix';
    }
    return null;
  }

  static bool _isBreak(int codeUnit) {
    return codeUnit == 0x20 || codeUnit == 0x0A || codeUnit == 0x09;
  }
}

class _FilterResolution {
  const _FilterResolution({
    required this.eligibleLogIds,
    required this.matchedEntityNamesByLog,
  });

  /// Null when no filter constraint applied. Otherwise the set of log
  /// IDs that survive all active filters (empty set = zero matches).
  final Set<String>? eligibleLogIds;

  /// log id -> display names of selected entities mentioned in that log.
  /// Drives the entity-boost ranking signal and the result-tile chips.
  final Map<String, List<String>> matchedEntityNamesByLog;
}
