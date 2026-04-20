import 'package:meta/meta.dart';

import 'memory.dart';

/// A memory that survived [MemoryRetriever.retrieve], carrying the
/// intermediate scores so the caller can debug retrieval quality.
///
/// Mirrors `RankedChunk` in shape, minus the rerank score (the memory
/// corpus is small enough that we skip the LLM rerank stage).
@immutable
final class RankedMemory {
  const RankedMemory({
    required this.memory,
    required this.fusedScore,
    required this.rrfScore,
    required this.timeDecayFactor,
    this.bm25Rank,
    this.vectorRank,
  });

  final Memory memory;

  /// Final orderable score: RRF × time-decay.
  final double fusedScore;

  /// Sum of 1/(k+rank) across BM25 + vector ranking lists.
  final double rrfScore;

  /// Decay multiplier in (0, 1]. 1.0 when decay is disabled.
  final double timeDecayFactor;

  /// 0-indexed rank within the BM25 result list, or null if absent.
  final int? bm25Rank;

  /// 0-indexed rank within the vector search list, or null if absent.
  final int? vectorRank;

  @override
  String toString() =>
      'RankedMemory(${memory.id.raw} '
      'fused=${fusedScore.toStringAsFixed(3)} '
      'rrf=${rrfScore.toStringAsFixed(3)} '
      'decay=${timeDecayFactor.toStringAsFixed(2)})';
}
