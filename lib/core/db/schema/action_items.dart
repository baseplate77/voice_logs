import 'package:drift/drift.dart';

/// Action items extracted from refined voice logs.
///
/// These are local-only user-facing tasks, reminders, decisions, and follow-up
/// items. Evidence points back into the source voice log so users can audit why
/// an action exists.
class ActionItems extends Table {
  TextColumn get id => text()();

  /// Source voice log id.
  TextColumn get voiceLogId => text()();

  /// One of: task, reminder, decision, follow_up.
  TextColumn get type => text()();

  TextColumn get title => text()();
  TextColumn get notes => text().nullable()();

  /// Due/reminder time in Unix milliseconds, if the model found one.
  IntColumn get dueAt => integer().nullable()();

  /// One of: pending, done, archived.
  TextColumn get status => text()();

  /// Stable platform notification id when a reminder notification is scheduled.
  IntColumn get notificationId => integer().nullable()();
  IntColumn get notificationScheduledAt => integer().nullable()();

  TextColumn get evidenceText => text()();
  IntColumn get startChar => integer()();
  IntColumn get endChar => integer()();
  RealColumn get confidence => real()();

  IntColumn get createdAt => integer()();
  IntColumn get updatedAt => integer()();
  IntColumn get completedAt => integer().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}
