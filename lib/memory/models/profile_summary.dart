import 'package:meta/meta.dart';

import 'memory.dart';

/// Always-on "about me" context injected into every
/// [MemoryAwareQuerySynthesizer] call.
///
/// Compiled from the top active [FactMemory]s + open [GoalMemory]s +
/// recent [DecisionMemory]s by [ProfileBuilder]. Hard-capped at
/// ~300 tokens so it doesn't crowd out retrieved chunks in the prompt
/// window.
@immutable
final class ProfileSummary {
  const ProfileSummary({
    required this.summary,
    required this.updatedAt,
    required this.sourceMemoryIds,
    required this.isStale,
  });

  /// The natural-language "about me" blurb. Empty string when no
  /// memories exist yet (fresh install, or every memory archived).
  final String summary;

  final DateTime updatedAt;

  /// Ids of memories whose content contributed to this summary. The
  /// builder checks these on stale-flag set: if a material memory
  /// outside this set is touched, we don't bother rebuilding.
  final List<MemoryId> sourceMemoryIds;

  /// True when a relevant memory has mutated since `updatedAt`. The
  /// builder rebuilds lazily on next `current()` call when stale.
  final bool isStale;

  /// Empty profile used before any memories exist. Getter (not const)
  /// because [DateTime.fromMillisecondsSinceEpoch] isn't a const ctor.
  static ProfileSummary get empty => ProfileSummary(
        summary: '',
        updatedAt: DateTime.fromMillisecondsSinceEpoch(0),
        sourceMemoryIds: const <MemoryId>[],
        isStale: false,
      );

  @override
  String toString() =>
      'ProfileSummary(${summary.length} chars, '
      '${sourceMemoryIds.length} sources, stale=$isStale)';
}
