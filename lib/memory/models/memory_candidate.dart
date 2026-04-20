import 'package:meta/meta.dart';

import 'memory.dart';

/// Pre-consolidation shape produced by [MemoryExtractor].
///
/// Candidates don't have ids yet — the consolidator decides whether
/// this candidate becomes a new [Memory] row, merges into an existing
/// one, or supersedes an older one. Once that decision is made the
/// repository mints a [MemoryId] and writes the record.
@immutable
final class MemoryCandidate {
  const MemoryCandidate({
    required this.kind,
    required this.title,
    required this.content,
    required this.confidence,
    required this.sourceChunkIds,
    this.occurredAt,
    this.dueAt,
    this.goalState,
    this.entityNames = const <String>[],
  })  : assert(confidence >= 0.0 && confidence <= 1.0),
        assert(title.length > 0),
        assert(content.length > 0);

  final MemoryKind kind;
  final String title;
  final String content;
  final double confidence;

  /// Chunk ids the extractor matched this candidate to (by text
  /// overlap against the supplied `CleanedTranscript`).
  final List<int> sourceChunkIds;

  /// Required for [MemoryKind.decision] and [MemoryKind.episode]; null
  /// otherwise. The consolidator drops malformed candidates.
  final DateTime? occurredAt;

  /// Optional for [MemoryKind.goal].
  final DateTime? dueAt;

  /// Required for [MemoryKind.goal].
  final GoalState? goalState;

  /// Canonical names of entities the extractor referenced. The
  /// consolidator resolves these to `entities.id` by lookup; unmatched
  /// names are dropped.
  final List<String> entityNames;

  @override
  String toString() =>
      'MemoryCandidate($kind "$title" conf=${confidence.toStringAsFixed(2)})';
}
