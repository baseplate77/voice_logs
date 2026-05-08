import 'package:drift/drift.dart';

import 'memory_items.dart';
import 'voice_logs.dart';

/// Evidence linking a memory card back to the source voice log text.
class MemorySources extends Table {
  /// Stable local id.
  TextColumn get id => text()();

  /// Owning memory card.
  TextColumn get memoryId => text().references(MemoryItems, #id)();

  /// Source voice log.
  TextColumn get voiceLogId => text().references(VoiceLogs, #id)();

  /// Start char offset in the cleaned transcript used for extraction.
  IntColumn get startChar => integer()();

  /// End char offset in the cleaned transcript used for extraction.
  IntColumn get endChar => integer()();

  /// Exact evidence text recovered from the cleaned transcript.
  TextColumn get evidenceText => text()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}
