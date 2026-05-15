import 'package:drift/drift.dart';

import 'voice_logs.dart';

/// Smart "Ask my journal" prompt suggestions extracted from each refined log.
///
/// Each row is a single tappable chip in the Ask screen header. The chip
/// surfaces as [chipText] (short topic label, e.g. "Coffee with Shivani") and
/// when tapped the full [question] (e.g. "What did I discuss with Shivani
/// over coffee?") is submitted to the Ask pipeline. Usage counters drive the
/// selector so over-tapped chips don't dominate the rotation while fresh ones
/// always get a turn.
class PromptSuggestions extends Table {
  TextColumn get id => text()();

  /// Source voice log id. Suggestions are deleted with their log.
  TextColumn get logId => text().references(VoiceLogs, #id)();

  /// Short, chip-sized topic label (target 3-5 words).
  TextColumn get chipText => text()();

  /// Fully-formed question dispatched to Ask when the chip is tapped.
  TextColumn get question => text()();

  /// Bumped whenever the chip is tapped. Drives ranking so popular chips
  /// keep returning and unused ones get rotated out.
  IntColumn get usedCount => integer().withDefault(const Constant(0))();

  /// Unix milliseconds the chip was last tapped, or null if never used.
  IntColumn get lastUsedAt => integer().nullable()();

  /// Unix milliseconds when the suggestion was extracted.
  IntColumn get createdAt => integer()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}
