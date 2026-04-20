import 'package:meta/meta.dart';

import '../core/errors.dart';
import '../core/logger.dart';
import '../core/result.dart';
import '../retrieve/hybrid_retriever.dart';
import '../retrieve/models/ranked_chunk.dart';

/// A single week-bucket of chunks the synthesizer will render in
/// chronological order. ISO weeks start on Monday 00:00 UTC; normalising
/// on UTC keeps cluster boundaries stable across DST transitions.
@immutable
final class WeekCluster {
  const WeekCluster({required this.weekStart, required this.chunks});

  /// Monday 00:00 UTC of the ISO week this cluster belongs to.
  final DateTime weekStart;

  /// Chunks retrieved inside [weekStart, weekStart + 7d), best-first.
  final List<RankedChunk> chunks;

  @override
  String toString() =>
      'WeekCluster($weekStart, ${chunks.length} chunks)';
}

/// First-hop limit — bigger than a single RAG call because we need
/// week-level recall, not just top-k. Trades LLM budget for coverage.
const int kMultiHopBroadLimit = 30;

/// Per-week second-hop limit. 3 chunks × ~8 weeks ≈ 24 chunks; fits in
/// Gemma 3 1B's 8k context with room for the prompt wrapper.
const int kMultiHopPerWeekLimit = 3;

/// Weeks with fewer than this many broad-hop hits are dropped before
/// the second hop. A single mention per week is usually noise — the
/// broad pass already surfaced it, densifying adds nothing.
const int kMultiHopMinHitsPerWeek = 2;

/// Two-hop temporal retrieval. Called by [QuerySynthesizer] when the
/// question trips the temporal trigger (IMPLEMENTATION_PLAN §7). The
/// single-shot hybrid path top-k's toward the most-recent mention and
/// can't see the arc; this one clusters by week, densifies each
/// interesting week, then hands the chronological series to the LLM.
///
/// Algorithm:
///   1. Broad hop: [HybridRetriever.retrieve] with
///      [kMultiHopBroadLimit] results.
///   2. Cluster by ISO week of `chunk.createdAt`, dropping weeks with
///      fewer than [kMultiHopMinHitsPerWeek] hits.
///   3. For each surviving week, re-retrieve with a [DateRange]
///      restricted to that week — the reranker re-scores within the
///      bucket instead of across the whole corpus.
///   4. Return clusters ordered chronologically.
class MultiHopRetriever {
  MultiHopRetriever({
    required this.retriever,
    AppLogger? logger,
  }) : _logger = logger ?? AppLogger();

  final HybridRetriever retriever;
  final AppLogger _logger;

  /// Run the two-hop retrieval. Returns an empty list (wrapped in [Ok])
  /// when the query is empty or the broad hop returns nothing — the
  /// caller can fall back to the simple path without branching on an
  /// error.
  Future<Result<List<WeekCluster>, AppError>> retrieveTemporal(
    String question, {
    int broadLimit = kMultiHopBroadLimit,
    int perWeekLimit = kMultiHopPerWeekLimit,
    int minHitsPerWeek = kMultiHopMinHitsPerWeek,
  }) async {
    if (question.trim().isEmpty) {
      return const Ok<List<WeekCluster>, AppError>(<WeekCluster>[]);
    }

    final broad = await retriever.retrieve(question, limit: broadLimit);
    if (broad.isErr) {
      return Err<List<WeekCluster>, AppError>(broad.errOrNull!);
    }
    final broadChunks = broad.okOrNull!;
    if (broadChunks.isEmpty) {
      return const Ok<List<WeekCluster>, AppError>(<WeekCluster>[]);
    }

    final byWeek = <DateTime, List<RankedChunk>>{};
    for (final chunk in broadChunks) {
      final weekStart = isoWeekStart(chunk.chunk.createdAt);
      byWeek.putIfAbsent(weekStart, () => <RankedChunk>[]).add(chunk);
    }

    final clusters = <WeekCluster>[];
    for (final entry in byWeek.entries) {
      if (entry.value.length < minHitsPerWeek) continue;
      final weekStart = entry.key;
      // Inclusive upper bound — DateRange.contains uses !isAfter(to),
      // so subtracting a ms from +7d keeps the range half-open and
      // prevents a chunk on the following Monday 00:00 from landing in
      // two buckets.
      final weekEnd = weekStart
          .add(const Duration(days: 7))
          .subtract(const Duration(milliseconds: 1));
      final dense = await retriever.retrieve(
        question,
        limit: perWeekLimit,
        dateRange: DateRange(from: weekStart, to: weekEnd),
      );
      if (dense.isErr) {
        _logger.warn(
          'multi-hop week retrieve failed for $weekStart: '
          '${dense.errOrNull}',
        );
        continue;
      }
      final hits = dense.okOrNull!;
      if (hits.isEmpty) continue;
      clusters.add(WeekCluster(weekStart: weekStart, chunks: hits));
    }

    clusters.sort((a, b) => a.weekStart.compareTo(b.weekStart));
    return Ok<List<WeekCluster>, AppError>(clusters);
  }

  /// Monday 00:00 UTC of the ISO week containing [t]. Exported so
  /// synthesizers and tests can share the same bucketing rule.
  static DateTime isoWeekStart(DateTime t) {
    final utc = t.toUtc();
    final day = DateTime.utc(utc.year, utc.month, utc.day);
    final daysFromMonday = day.weekday - DateTime.monday;
    return day.subtract(Duration(days: daysFromMonday));
  }
}
