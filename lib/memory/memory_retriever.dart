import '../core/errors.dart';
import '../core/logger.dart';
import '../core/result.dart';
import '../embed/embedder.dart';
import '../retrieve/rrf.dart';
import '../retrieve/time_decay.dart';
import '../store/app_database.dart';
import 'memory_repository.dart';
import 'memory_vector_index.dart';
import 'models/memory.dart';
import 'models/ranked_memory.dart';

/// Number of candidates pulled per backend (BM25 + vector). Tighter
/// than Phase 5's 30 because the memory corpus is smaller and we skip
/// the LLM rerank stage — 20 is plenty for recall@5.
const int kMemoryRetrievePerBackend = 20;

/// Default half-life for memory time-decay. Set to `double.infinity` by
/// default — memories are meant to be durable; the retriever only
/// decays when the caller opts in. We use `double.infinity` to mean
/// "disabled" via the [timeDecayFactor] guard.
const double kMemoryDefaultHalfLifeDays = double.infinity;

/// Default set of statuses surfaced by retrieval. Archived /
/// superseded stay out unless the caller explicitly asks.
const List<MemoryStatus> kDefaultRetrievableStatuses = <MemoryStatus>[
  MemoryStatus.active,
];

/// Hybrid retrieval over the memory store. Mirrors Phase 5's
/// [HybridRetriever] in shape but without the LLM rerank step — the
/// memory corpus is small enough that RRF + time decay is sufficient.
///
/// Pipeline:
///   1. FTS5 BM25 on `memories_fts` (title + body) → top-K ids.
///   2. ObjectBox cosine over memory embeddings → top-K ids.
///   3. Reciprocal Rank Fusion across the two lists.
///   4. Status filter + optional time decay.
///   5. Return top [limit] by fused score.
class MemoryRetriever {
  MemoryRetriever({
    required this.db,
    required this.repository,
    required this.embedder,
    required this.vectorIndex,
    AppLogger? logger,
    DateTime Function()? clock,
  })  : _logger = logger ?? AppLogger(),
        _now = clock ?? DateTime.now;

  final AppDatabase db;
  final MemoryRepository repository;
  final Embedder embedder;
  final MemoryVectorIndex vectorIndex;

  final AppLogger _logger;
  final DateTime Function() _now;

  Future<Result<List<RankedMemory>, AppError>> retrieve(
    String query, {
    int limit = 5,
    List<MemoryStatus> statuses = kDefaultRetrievableStatuses,
    double halfLifeDays = kMemoryDefaultHalfLifeDays,
  }) async {
    if (query.trim().isEmpty) {
      return const Ok<List<RankedMemory>, AppError>(<RankedMemory>[]);
    }
    try {
      final sanitised = _sanitiseFtsQuery(query);
      final bm25Future = sanitised.isEmpty
          ? Future.value(const <String>[])
          : _bm25Ids(sanitised, statuses: statuses);
      final vectorFuture = _vectorIds(query);

      final results = await Future.wait(<Future<List<String>>>[
        bm25Future,
        vectorFuture,
      ]);
      final bm25Ids = results[0];
      final vectorIds = results[1];

      final fused = reciprocalRankFusionScored<String>(
        <List<String>>[bm25Ids, vectorIds],
      );
      if (fused.isEmpty) {
        return const Ok<List<RankedMemory>, AppError>(<RankedMemory>[]);
      }

      // Hydrate the fused top ids to full Memory objects; preserve
      // fused-score order so we can apply time decay and cut off by
      // limit in one pass.
      final topIds = fused.keys.take(kMemoryRetrievePerBackend).toList();
      final memoriesR = await repository.getMany(
        topIds.map(MemoryId.new).toList(growable: false),
      );
      if (memoriesR.isErr) {
        return Err<List<RankedMemory>, AppError>(memoriesR.errOrNull!);
      }
      final memories = memoriesR.okOrNull!;

      // Re-apply the status filter after hydration — in case the FTS
      // index lags behind a recent status flip (triggers are immediate
      // in our case, but the defensive guard is cheap).
      final allowed = <MemoryStatus>{...statuses};
      final filtered =
          memories.where((m) => allowed.contains(m.status)).toList();

      final bm25Rank = _rankIndex(bm25Ids);
      final vectorRank = _rankIndex(vectorIds);
      final now = _now();
      final ranked = <RankedMemory>[];
      for (final m in filtered) {
        final rrf = fused[m.id.raw] ?? 0.0;
        final decay = halfLifeDays.isFinite
            ? timeDecayBetween(
                now: now,
                createdAt: m.updatedAt,
                halfLifeDays: halfLifeDays,
              )
            : 1.0;
        ranked.add(
          RankedMemory(
            memory: m,
            fusedScore: rrf * decay,
            rrfScore: rrf,
            timeDecayFactor: decay,
            bm25Rank: bm25Rank[m.id.raw],
            vectorRank: vectorRank[m.id.raw],
          ),
        );
      }
      ranked.sort((a, b) => b.fusedScore.compareTo(a.fusedScore));
      if (ranked.length > limit) {
        return Ok<List<RankedMemory>, AppError>(
          ranked.sublist(0, limit),
        );
      }
      return Ok<List<RankedMemory>, AppError>(ranked);
    } on Object catch (e, st) {
      _logger.error('memory retrieve failed',
          error: e, stackTrace: st);
      return Err<List<RankedMemory>, AppError>(
        UnknownError('memory retrieve failed', cause: e, stackTrace: st),
      );
    }
  }

  Future<List<String>> _bm25Ids(
    String query, {
    required List<MemoryStatus> statuses,
  }) async {
    try {
      return await db.searchMemoryIds(
        query,
        statuses: statuses
            .map((s) => switch (s) {
                  MemoryStatus.active => 'active',
                  MemoryStatus.superseded => 'superseded',
                  MemoryStatus.resolved => 'resolved',
                  MemoryStatus.archived => 'archived',
                })
            .toList(growable: false),
      );
    } on Object catch (e) {
      _logger.warn('memory BM25 search failed: $e');
      return const <String>[];
    }
  }

  Future<List<String>> _vectorIds(String query) async {
    final embedR = await embedder.embedQuery(query);
    if (embedR.isErr) {
      _logger.warn('embedQuery failed for memory retrieval');
      return const <String>[];
    }
    final matches = vectorIndex.nearest(
      embedR.okOrNull!,
      kMemoryRetrievePerBackend,
    );
    return matches.map((m) => m.memoryId).toList(growable: false);
  }

  static Map<String, int> _rankIndex(List<String> list) {
    final out = <String, int>{};
    for (var i = 0; i < list.length; i++) {
      out[list[i]] = i;
    }
    return out;
  }

  /// Strip FTS5 operators, wrap each term in quotes, add a prefix `*`
  /// to the last term — same pattern as
  /// [VoiceLogRepository._sanitiseFtsQuery].
  static String _sanitiseFtsQuery(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return '';
    final cleaned = trimmed.replaceAll(RegExp(r'[^\w\s\u00A0-\uFFFF]'), ' ');
    final tokens = cleaned.split(RegExp(r'\s+'))
      ..removeWhere((t) => t.isEmpty);
    if (tokens.isEmpty) return '';
    final parts = <String>[];
    for (var i = 0; i < tokens.length; i++) {
      final t = tokens[i];
      parts.add(i == tokens.length - 1 ? '"$t"*' : '"$t"');
    }
    return parts.join(' ');
  }
}
