import 'dart:math' as math;

import '../../core/db/repositories/prompt_suggestion_repository.dart';

/// Selects which prompt suggestion chips to display in the Ask header.
///
/// Composition for the default k=5:
///   - up to 2 fresh chips from the last 7 days, newest first;
///   - up to 2 random picks weighted to favor low [usedCount] so seldom-seen
///     chips surface (variety over recency);
///   - up to 1 "top used" slot for the chip the user reaches for most;
///   - any remaining slots filled at random from the rest of the pool.
///
/// Dedup is by suggestion id. The function is pure — pass [now] and an
/// optional [random] explicitly so tests can be deterministic.
class PromptSuggestionSelector {
  const PromptSuggestionSelector({
    this.recentSlots = 2,
    this.randomSlots = 2,
    this.topUsedSlots = 1,
    this.recentWindow = const Duration(days: 7),
  });

  final int recentSlots;
  final int randomSlots;
  final int topUsedSlots;
  final Duration recentWindow;

  List<PromptSuggestionView> pick(
    List<PromptSuggestionView> pool, {
    required DateTime now,
    int limit = 5,
    math.Random? random,
  }) {
    if (pool.isEmpty || limit <= 0) return const [];
    final rng = random ?? math.Random();
    final picked = <String, PromptSuggestionView>{};

    void take(Iterable<PromptSuggestionView> ordered, int slots) {
      if (slots <= 0) return;
      var taken = 0;
      for (final s in ordered) {
        if (taken >= slots) break;
        if (picked.containsKey(s.id)) continue;
        if (picked.length >= limit) return;
        picked[s.id] = s;
        taken++;
      }
    }

    // Recent: newest createdAt within the recency window.
    final recentCutoff = now.subtract(recentWindow);
    final recent = pool.where((s) => s.createdAt.isAfter(recentCutoff)).toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    take(recent, recentSlots);

    // Top used: max usedCount, then most recently used as tiebreaker. Skip
    // chips that have never been tapped — the top-used slot is meant to
    // reward repeat asks, not pad the row.
    final used = pool.where((s) => s.usedCount > 0).toList()
      ..sort((a, b) {
        final byCount = b.usedCount.compareTo(a.usedCount);
        if (byCount != 0) return byCount;
        final aTs = a.lastUsedAt?.millisecondsSinceEpoch ?? 0;
        final bTs = b.lastUsedAt?.millisecondsSinceEpoch ?? 0;
        return bTs.compareTo(aTs);
      });
    take(used, topUsedSlots);

    // Random-weighted: favors low used_count. Weight = 1 / (1 + usedCount).
    final remaining = pool.where((s) => !picked.containsKey(s.id)).toList();
    if (remaining.isNotEmpty) {
      final weighted = _weightedShuffle(remaining, rng);
      take(weighted, randomSlots);
    }

    // Fill leftover slots from whatever pool entries are still untaken.
    if (picked.length < limit) {
      final leftovers = pool.where((s) => !picked.containsKey(s.id)).toList()
        ..shuffle(rng);
      take(leftovers, limit - picked.length);
    }

    final out = picked.values.toList()..shuffle(rng);
    return out;
  }

  /// Shuffles [items] giving lower-[usedCount] entries a higher probability
  /// of appearing earlier in the result. Uses the "exponential trick" so a
  /// single sort is enough — `-log(uniform) / weight` ranks items so smaller
  /// keys (= preferred) bubble to the front.
  List<PromptSuggestionView> _weightedShuffle(
    List<PromptSuggestionView> items,
    math.Random rng,
  ) {
    final keyed = items.map((s) {
      final weight = 1.0 / (1 + s.usedCount);
      final u = rng.nextDouble().clamp(1e-9, 1.0);
      return (key: -math.log(u) / weight, value: s);
    }).toList()..sort((a, b) => a.key.compareTo(b.key));
    return keyed.map((e) => e.value).toList(growable: false);
  }
}
