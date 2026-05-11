import 'package:drift/drift.dart';

/// Durable local memory card extracted from one or more voice logs.
class MemoryItems extends Table {
  /// Stable local id.
  TextColumn get id => text()();

  /// One of: identity, preference, relationship, project, routine, place,
  /// event_context.
  TextColumn get type => text()();

  /// User-visible memory text.
  TextColumn get memoryText => text().named('text')();

  /// Lowercase/collapsed text used for dedupe and FTS.
  TextColumn get normalizedText => text()();

  /// Confidence in [0, 1], raised as repeated evidence appears.
  RealColumn get confidence => real()();

  /// One of: candidate, active, archived, deleted.
  TextColumn get status => text()();

  /// One of: normal, sensitive.
  TextColumn get sensitivity => text()();

  /// Unix milliseconds when first observed.
  IntColumn get firstSeenAt => integer()();

  /// Unix milliseconds when most recently observed.
  IntColumn get lastSeenAt => integer()();

  /// Unix milliseconds when row was created.
  IntColumn get createdAt => integer()();

  /// Unix milliseconds when row was updated.
  IntColumn get updatedAt => integer()();

  /// Deterministic importance score in [0, 1]. Used for promotion and ranking.
  RealColumn get importanceScore => real().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}
