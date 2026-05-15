import 'package:drift/drift.dart';

import 'ask_threads.dart';

/// One persisted user/assistant message inside an Ask Journal thread.
class AskMessages extends Table {
  TextColumn get id => text()();
  TextColumn get threadId => text().references(AskThreads, #id)();

  /// `user` or `assistant`.
  TextColumn get role => text()();

  TextColumn get messageText => text().named('text')();

  /// JSON snapshots of retrieved voice-log sources for assistant answers.
  TextColumn get logHitsJson => text().nullable()();

  /// JSON snapshots of retrieved memory sources for assistant answers.
  TextColumn get memoryHitsJson => text().nullable()();

  /// 1 while the assistant response is still streaming; reset to 0 on finish.
  IntColumn get streaming => integer().withDefault(const Constant(0))();

  IntColumn get createdAt => integer()();
  IntColumn get updatedAt => integer()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}
