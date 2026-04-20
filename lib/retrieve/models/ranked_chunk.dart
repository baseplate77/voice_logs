import 'package:meta/meta.dart';

import '../../store/models/voice_log_record.dart';

/// A chunk that survived hybrid retrieval, carrying every intermediate
/// score so retrieval quality is debuggable end-to-end.
///
/// `fusedScore` is the final ordering key; the individual contributors
/// are kept so UI + tests can surface "this chunk is at the top
/// because of rerank, not BM25" without re-running retrieval.
@immutable
final class RankedChunk {
  const RankedChunk({
    required this.chunk,
    required this.fusedScore,
    required this.rrfScore,
    required this.rerankScore,
    required this.timeDecayFactor,
    this.bm25Rank,
    this.vectorRank,
  });

  final ChunkRecord chunk;

  /// Final orderable score: rerank × time-decay (when rerank ran) or
  /// RRF × time-decay (when rerank skipped/failed). Larger = better.
  final double fusedScore;

  /// Sum of 1/(k+rank) across every ranking list this chunk appeared
  /// in (original query BM25 + vectors, per paraphrase likewise).
  final double rrfScore;

  /// LLM-assigned relevance 0.0–1.0. `double.nan` when rerank was
  /// skipped or failed — callers can check `rerankScore.isNaN` to
  /// distinguish "not reranked" from "scored 0".
  final double rerankScore;

  /// Decay multiplier applied to fused score. In (0, 1].
  final double timeDecayFactor;

  /// 0-indexed rank within the BM25 result list, or null if missing.
  final int? bm25Rank;

  /// 0-indexed rank within the vector search list, or null if missing.
  final int? vectorRank;

  @override
  String toString() =>
      'RankedChunk(#${chunk.id} fused=${fusedScore.toStringAsFixed(3)} '
      'rrf=${rrfScore.toStringAsFixed(3)} '
      'rerank=${rerankScore.isNaN ? "n/a" : rerankScore.toStringAsFixed(2)} '
      'decay=${timeDecayFactor.toStringAsFixed(2)})';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is RankedChunk &&
          other.chunk == chunk &&
          other.fusedScore == fusedScore &&
          other.rrfScore == rrfScore &&
          (_bothNaN(other.rerankScore, rerankScore) ||
              other.rerankScore == rerankScore) &&
          other.timeDecayFactor == timeDecayFactor &&
          other.bm25Rank == bm25Rank &&
          other.vectorRank == vectorRank);

  @override
  int get hashCode => Object.hash(
        chunk,
        fusedScore,
        rrfScore,
        rerankScore.isNaN ? 'nan' : rerankScore,
        timeDecayFactor,
        bm25Rank,
        vectorRank,
      );

  static bool _bothNaN(double a, double b) => a.isNaN && b.isNaN;
}

/// Optional date filter for [HybridRetriever.retrieve]. Inclusive on
/// both ends.
@immutable
final class DateRange {
  const DateRange({required this.from, required this.to})
      : assert(true, 'from <= to is enforced at use-site');

  final DateTime from;
  final DateTime to;

  bool contains(DateTime t) =>
      !t.isBefore(from) && !t.isAfter(to);

  @override
  String toString() => 'DateRange($from..$to)';
}
