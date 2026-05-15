import 'package:drift/drift.dart';

/// One persisted Ask Journal conversation.
class AskThreads extends Table {
  /// UUID-ish local id.
  TextColumn get id => text()();

  /// Short title shown in the chat history sheet.
  TextColumn get title => text()();

  IntColumn get createdAt => integer()();
  IntColumn get updatedAt => integer()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}
