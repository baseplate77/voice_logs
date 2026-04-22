import 'package:drift/drift.dart';

import 'voice_logs.dart';

/// Persistent queue entry consumed by the single worker isolate. On app
/// resume the isolate reloads any job whose [state] is `pending` or
/// `running` (crash recovery).
class ProcessingJobs extends Table {
  /// UUID v4.
  TextColumn get id => text()();

  /// Owning voice log.
  TextColumn get logId => text().references(VoiceLogs, #id)();

  /// One of: `refine` | `embed` | `canonicalize`.
  TextColumn get jobType => text()();

  /// Lower value = runs first (FIFO within the same priority).
  IntColumn get priority => integer()();

  /// Unix milliseconds at enqueue time.
  IntColumn get enqueuedAt => integer()();

  /// One of: `pending` | `running` | `done` | `failed`.
  TextColumn get state => text()();

  /// Retry counter — incremented each time this job transitions out of
  /// `running` back to `pending` due to a transient error.
  IntColumn get attempts => integer().withDefault(const Constant(0))();

  @override
  Set<Column<Object>> get primaryKey => {id};
}
