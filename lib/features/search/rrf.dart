/// Reciprocal rank fusion — merge multiple ranked result lists into one.
///
/// For each item, RRF sums `1 / (k + rank)` across lists. `k` is a
/// smoothing constant; the canonical value is 60. The bigger k, the less
/// weight the top ranks have, which helps when different retrievers
/// disagree about ordering in the head.
Map<String, double> reciprocalRankFusion({
  required List<List<String>> rankedLists,
  int k = 60,
}) {
  final scores = <String, double>{};
  for (final list in rankedLists) {
    for (var rank = 0; rank < list.length; rank++) {
      final id = list[rank];
      scores[id] = (scores[id] ?? 0) + 1.0 / (k + rank + 1);
    }
  }
  return scores;
}

/// Sort a fused-score map into a descending ranked list.
List<String> sortByScoreDescending(Map<String, double> scores) {
  final entries = scores.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  return entries.map((e) => e.key).toList();
}
