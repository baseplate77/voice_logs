import 'package:drift/drift.dart';

/// Unified summary table for per-log, daily, weekly, and topic summaries.
/// Evidence is traced back to source segments via [sourceChunkIdsJson].
class Summaries extends Table {
  TextColumn get id => text()();

  /// One of: log, daily, weekly, topic.
  TextColumn get type => text()();

  /// For log: the voice_log_id. For daily: date string (yyyy-MM-dd).
  /// For weekly: week range. For topic: topic string.
  TextColumn get sourceId => text()();

  TextColumn get title => text()();
  TextColumn get body => text()();
  TextColumn get topicsJson => text().nullable()();
  TextColumn get actionItemsJson => text().nullable()();
  TextColumn get decisionsJson => text().nullable()();
  TextColumn get mood => text().nullable()();

  /// JSON array of segment/chunk IDs for evidence tracing.
  TextColumn get sourceChunkIdsJson => text()();

  /// 0 = fresh, 1 = needs regeneration.
  IntColumn get stale => integer().withDefault(const Constant(0))();

  IntColumn get generatedAt => integer()();
  IntColumn get createdAt => integer()();
  IntColumn get updatedAt => integer()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}
