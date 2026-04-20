import 'package:meta/meta.dart';

import 'memory.dart';

/// Outcome of running [MemoryConsolidator.consolidate] on a batch of
/// candidates. Tells the caller which candidates landed as new memories,
/// which merged into existing ones, and which superseded an older record.
@immutable
final class ConsolidationResult {
  const ConsolidationResult({
    required this.created,
    required this.merged,
    required this.superseded,
    required this.dropped,
  });

  /// Candidates that became brand-new rows.
  final List<Memory> created;

  /// Candidates that merged into an existing memory; the carried value
  /// is the *updated* row (with unioned sources + bumped confidence).
  final List<Memory> merged;

  /// Candidates that superseded an older memory. `old` is the row now
  /// marked [MemoryStatus.superseded]; `replacement` is the freshly
  /// inserted row it points to.
  final List<SupersededPair> superseded;

  /// Candidates the judge classified as unrelated to the nearest
  /// neighbour but the consolidator chose not to persist — e.g. because
  /// the extractor's required fields were missing.
  final List<String> dropped;

  int get totalAccepted => created.length + merged.length + superseded.length;

  /// True when something actionable changed (for [ProfileBuilder]
  /// stale-flag logic — a pure-merge batch of 5 "I work at Acme"
  /// duplicates shouldn't rebuild the profile).
  bool get isStructurallyChanged =>
      created.isNotEmpty || superseded.isNotEmpty;

  @override
  String toString() =>
      'ConsolidationResult(created=${created.length} merged=${merged.length} '
      'superseded=${superseded.length} dropped=${dropped.length})';
}

/// One old → new pair from a consolidation pass.
@immutable
final class SupersededPair {
  const SupersededPair({required this.old, required this.replacement});

  final Memory old;
  final Memory replacement;

  @override
  String toString() =>
      'SupersededPair(${old.id.raw} → ${replacement.id.raw})';
}
