/// Reciprocal Rank Fusion constant. The plan uses k=60 — a
/// conventional value that softens the head of each list without
/// flattening rankings entirely.
const int kRrfDefaultK = 60;

/// Reciprocal Rank Fusion.
///
/// Given several ordered lists of the same id type (chunk ids in our
/// case), returns a merged list ordered best-first. Scores sum
/// `1 / (k + rank)` across appearances; items absent from a list
/// contribute nothing from that list.
///
/// Invariants:
/// - Each input list is treated as a ranking (position 0 = best).
/// - Duplicates inside a single list are respected — only the first
///   occurrence's rank contributes (RRF is usually applied to unique
///   rankings but be defensive).
/// - When an id ties in fused score, earlier-inserted id wins
///   (iteration order of [LinkedHashMap]).
List<T> reciprocalRankFusion<T>(
  List<List<T>> rankings, {
  int k = kRrfDefaultK,
}) {
  final scores = <T, double>{};
  for (final ranking in rankings) {
    final seen = <T>{};
    for (var i = 0; i < ranking.length; i++) {
      final id = ranking[i];
      if (!seen.add(id)) continue; // skip repeats within the list
      scores.update(
        id,
        (existing) => existing + 1.0 / (k + i + 1),
        ifAbsent: () => 1.0 / (k + i + 1),
      );
    }
  }
  // Stable sort by score desc. For ties, the map's insertion order
  // acts as the tiebreaker; converting via `entries` preserves that.
  final entries = scores.entries.toList(growable: false);
  entries.sort((a, b) => b.value.compareTo(a.value));
  return entries.map((e) => e.key).toList(growable: false);
}

/// Variant of [reciprocalRankFusion] that returns the ids *and* their
/// fused scores. Used by the retriever to pass the RRF score through
/// to [RankedChunk] for debugging.
Map<T, double> reciprocalRankFusionScored<T>(
  List<List<T>> rankings, {
  int k = kRrfDefaultK,
}) {
  final scores = <T, double>{};
  for (final ranking in rankings) {
    final seen = <T>{};
    for (var i = 0; i < ranking.length; i++) {
      final id = ranking[i];
      if (!seen.add(id)) continue;
      scores.update(
        id,
        (existing) => existing + 1.0 / (k + i + 1),
        ifAbsent: () => 1.0 / (k + i + 1),
      );
    }
  }
  final entries = scores.entries.toList(growable: false)
    ..sort((a, b) => b.value.compareTo(a.value));
  return <T, double>{for (final e in entries) e.key: e.value};
}
