import 'dart:math' as math;

/// Exponential time decay with a configurable half-life.
///
/// Multiply a relevance score by [timeDecayFactor] to fade older
/// chunks. One half-life elapsed → factor 0.5; two half-lives → 0.25.
/// IMPLEMENTATION_PLAN §6 calls this out as a common source of
/// off-by-one bugs, so every branch has an explicit test.
///
/// Formula: `exp(-age_days * ln(2) / halfLifeDays)`.
///
/// Clamps:
/// - `age < 0` is treated as `age = 0` (future timestamps can creep in
///   when clocks skew; no reason to boost them).
/// - `halfLife <= 0` returns 1.0 (no decay) — a 0-day half-life is a
///   misconfiguration, not an infinity.
double timeDecayFactor({
  required double ageDays,
  required double halfLifeDays,
}) {
  if (halfLifeDays <= 0) return 1.0;
  final effectiveAge = ageDays < 0 ? 0.0 : ageDays;
  return math.exp(-effectiveAge * math.ln2 / halfLifeDays);
}

/// Convenience: compute decay from two [DateTime]s. Returns a factor
/// in (0, 1]; identical instants yield 1.0.
double timeDecayBetween({
  required DateTime now,
  required DateTime createdAt,
  required double halfLifeDays,
}) {
  final ageMs = now.difference(createdAt).inMilliseconds;
  final ageDays = ageMs / Duration.millisecondsPerDay;
  return timeDecayFactor(ageDays: ageDays, halfLifeDays: halfLifeDays);
}
