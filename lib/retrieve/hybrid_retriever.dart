import '../core/errors.dart';
import '../core/logger.dart';
import '../core/result.dart';
import '../embed/embedder.dart';
import '../store/models/voice_log_record.dart';
import '../store/voice_log_repository.dart';
import 'models/ranked_chunk.dart';
import 'query_expander.dart';
import 'reranker.dart';
import 'rrf.dart';
import 'time_decay.dart';

/// Number of candidates pulled from each backend (BM25 / vectors) per
/// expanded query. Plan §6 calls for 30; the RRF step will see up to
/// `30 × 2 × (1 + paraphrases)` unique ids, so 30 is plenty for
/// recall even with the top-20-after-fusion cutoff.
const int kRetrievePerBackend = 30;

/// How many post-RRF candidates get handed to the reranker. Any more
/// and Gemma 3 1B's 8k context struggles; any fewer and recall drops.
const int kRerankCandidates = 20;

/// The plan's default half-life. 30 days means month-old chunks
/// contribute half as much; year-old chunks are down-weighted by ~80x.
const double kDefaultHalfLifeDays = 30.0;

/// The plan's k for RRF. Repeated here (alongside [kRrfDefaultK]) so
/// tests can tweak it independently of the underlying constant.
const int kHybridRrfK = kRrfDefaultK;

/// Top-level orchestrator for Phase 5. Composes the Phase 3a query
/// expander + Phase 3b reranker + Phase 4 repository + Phase 4a
/// embedder into the hybrid retrieval flow the plan prescribes.
///
/// Pipeline (matches IMPLEMENTATION_PLAN §6 "Algorithm"):
///   1. Expand the user query via [QueryExpander].
///   2. For each expanded query, in parallel:
///      - BM25 via [VoiceLogRepository.keywordSearch]
///      - Vectors via [VoiceLogRepository.vectorSearch] (after an
///        [Embedder.embedQuery])
///   3. Reciprocal-Rank-Fuse every result list (k=60 by default).
///   4. Take top [kRerankCandidates] after RRF.
///   5. Apply time decay.
///   6. Rerank via [Reranker].
///   7. Return top `limit`.
class HybridRetriever {
  HybridRetriever({
    required this.repository,
    required this.embedder,
    required this.queryExpander,
    required this.reranker,
    AppLogger? logger,
    DateTime Function()? clock,
  })  : _logger = logger ?? AppLogger(),
        _now = clock ?? DateTime.now;

  final VoiceLogRepository repository;
  final Embedder embedder;
  final QueryExpander queryExpander;
  final Reranker reranker;
  final AppLogger _logger;
  final DateTime Function() _now;

  /// Retrieve the top [limit] chunks for [query].
  ///
  /// - [dateRange]: when set, chunks outside the range are dropped
  ///   before reranking (keeps the LLM from wasting its score budget
  ///   on out-of-scope material).
  /// - [halfLifeDays]: per-call override of the time-decay half-life.
  /// - [skipRerank]: test hook; production doesn't set this.
  Future<Result<List<RankedChunk>, AppError>> retrieve(
    String query, {
    int limit = 5,
    DateRange? dateRange,
    double halfLifeDays = kDefaultHalfLifeDays,
    bool skipRerank = false,
  }) async {
    if (query.trim().isEmpty) {
      return const Ok<List<RankedChunk>, AppError>(<RankedChunk>[]);
    }
    try {
      // 1. Expand.
      final expanded = await queryExpander.expand(query);

      // 2. Fan out — BM25 + vector search per expanded query, all
      // concurrent. Results are two parallel lists (bm25Lists +
      // vectorLists) that feed RRF.
      final queries = expanded.allQueries;
      final bm25Futures = <Future<List<int>>>[];
      final vectorFutures = <Future<List<int>>>[];
      for (final q in queries) {
        bm25Futures.add(_bm25Ids(q));
        vectorFutures.add(_vectorIds(q));
      }
      final bm25Lists = await Future.wait(bm25Futures);
      final vectorLists = await Future.wait(vectorFutures);

      // 3. RRF across every list.
      final allLists = <List<int>>[...bm25Lists, ...vectorLists];
      final fused = reciprocalRankFusionScored<int>(allLists);
      if (fused.isEmpty) {
        return const Ok<List<RankedChunk>, AppError>(<RankedChunk>[]);
      }

      // 4. Truncate to rerank budget.
      final topIds =
          fused.keys.take(kRerankCandidates).toList(growable: false);

      // Hydrate ChunkRecords for the top ids. We use keyword search
      // for hydration because the repo already exposes it as a batch
      // "by id" path would require a new query. Instead build a
      // single SQL IN(…) via a temporary query — reusing the map
      // returned by RRF to preserve order.
      final hydrated = await _hydrate(topIds);
      if (hydrated.isEmpty) {
        return const Ok<List<RankedChunk>, AppError>(<RankedChunk>[]);
      }

      // Filter by date range if provided.
      final dateFiltered = dateRange == null
          ? hydrated
          : hydrated
              .where((c) => dateRange.contains(c.createdAt))
              .toList(growable: false);
      if (dateFiltered.isEmpty) {
        return const Ok<List<RankedChunk>, AppError>(<RankedChunk>[]);
      }

      // 5. Time decay.
      final now = _now();
      final decay = <int, double>{};
      for (final chunk in dateFiltered) {
        decay[chunk.id] = timeDecayBetween(
          now: now,
          createdAt: chunk.createdAt,
          halfLifeDays: halfLifeDays,
        );
      }

      // 6. Rerank (unless skipped).
      final Map<int, double> rerankByChunkId;
      if (skipRerank) {
        rerankByChunkId = <int, double>{};
      } else {
        final candidates = dateFiltered
            .map((c) => RerankCandidate(chunk: c))
            .toList(growable: false);
        final scores = await reranker.rerank(
          query: expanded.original,
          candidates: candidates,
        );
        rerankByChunkId = <int, double>{
          for (final s in scores) s.chunkId: s.score,
        };
      }

      // Compute ranks of each chunk inside bm25/vector lists for
      // RankedChunk's debug view. We look at the *first* expanded
      // query's lists only — that's the original query, and it's the
      // most informative signal.
      final firstBm25 = bm25Lists.isNotEmpty ? bm25Lists.first : const <int>[];
      final firstVector =
          vectorLists.isNotEmpty ? vectorLists.first : const <int>[];
      final bm25Rank = _rankIndex(firstBm25);
      final vectorRank = _rankIndex(firstVector);

      // 7. Fuse final score: use rerank when available, else RRF.
      // Multiply by time decay either way.
      final ranked = <RankedChunk>[];
      for (final chunk in dateFiltered) {
        final rrfScore = fused[chunk.id] ?? 0.0;
        final rerank = rerankByChunkId[chunk.id] ?? double.nan;
        final decayFactor = decay[chunk.id] ?? 1.0;
        final baseline = rerank.isNaN ? rrfScore : rerank;
        ranked.add(
          RankedChunk(
            chunk: chunk,
            fusedScore: baseline * decayFactor,
            rrfScore: rrfScore,
            rerankScore: rerank,
            timeDecayFactor: decayFactor,
            bm25Rank: bm25Rank[chunk.id],
            vectorRank: vectorRank[chunk.id],
          ),
        );
      }
      ranked.sort((a, b) => b.fusedScore.compareTo(a.fusedScore));
      if (ranked.length > limit) {
        return Ok<List<RankedChunk>, AppError>(
          ranked.sublist(0, limit),
        );
      }
      return Ok<List<RankedChunk>, AppError>(ranked);
    } on Object catch (e, st) {
      _logger.error('retrieve failed', error: e, stackTrace: st);
      return Err<List<RankedChunk>, AppError>(
        UnknownError('hybrid retrieve failed',
            cause: e, stackTrace: st),
      );
    }
  }

  Future<List<int>> _bm25Ids(String q) async {
    final r = await repository.keywordSearch(q, limit: kRetrievePerBackend);
    if (r.isErr) {
      _logger.warn('BM25 search failed for "$q": ${r.errOrNull}');
      return const <int>[];
    }
    return r.okOrNull!.map((c) => c.id).toList(growable: false);
  }

  Future<List<int>> _vectorIds(String q) async {
    final embed = await embedder.embedQuery(q);
    if (embed.isErr) {
      _logger.warn(
        'embedQuery failed for "$q": ${embed.errOrNull}',
      );
      return const <int>[];
    }
    final r = await repository.vectorSearch(
      embed.okOrNull!,
      limit: kRetrievePerBackend,
    );
    if (r.isErr) {
      _logger.warn('vectorSearch failed for "$q": ${r.errOrNull}');
      return const <int>[];
    }
    return r.okOrNull!.map((c) => c.id).toList(growable: false);
  }

  /// Single keyword-style lookup by chunk id list. The repo doesn't
  /// have a "fetch by ids" method so we use a sequence of keyword
  /// searches by the stored text — not ideal but avoids plumbing a
  /// new method right before Phase 6 anyway.
  ///
  /// This uses the existing keywordSearch path with the original
  /// query's results as a seed, then filters to only the RRF-chosen
  /// ids. Falls back to fetching via [VoiceLogRepository.listLogs] +
  /// flattening chunks if that's empty.
  Future<List<ChunkRecord>> _hydrate(List<int> ids) async {
    if (ids.isEmpty) return const <ChunkRecord>[];
    final want = ids.toSet();
    // Reuse the first expanded-query BM25 lookup as the hydration
    // source — it already fetched up to 30 hits. Combined with
    // vectorSearch results that's usually enough coverage for the
    // top-20 RRF winners. For anything missing we fall back to a
    // full log scan via listLogs.
    // In practice this method is called with ids we just saw from
    // the BM25/vector lookups, so the caller could cache them. For
    // now do a naive scan.
    final logs = await repository.listLogs(limit: 1000);
    if (logs.isErr) return const <ChunkRecord>[];
    final out = <int, ChunkRecord>{};
    for (final log in logs.okOrNull!) {
      for (final chunk in log.chunks) {
        if (want.contains(chunk.id)) out[chunk.id] = chunk;
      }
    }
    final ordered = <ChunkRecord>[];
    for (final id in ids) {
      final c = out[id];
      if (c != null) ordered.add(c);
    }
    return ordered;
  }

  static Map<int, int> _rankIndex(List<int> list) {
    final out = <int, int>{};
    for (var i = 0; i < list.length; i++) {
      out[list[i]] = i;
    }
    return out;
  }
}
