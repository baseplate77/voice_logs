import 'package:drift/drift.dart';

import 'voice_logs.dart';

/// One row per text segment produced by the embedding pipeline. The
/// [embedding] blob stores the L2-normalized Float32 vector (384 dims
/// for e5-small-v2) so cosine similarity reduces to a dot product.
///
/// When the sqlite-vec extension ships, the vector column moves into a
/// virtual table — this table keeps the segment metadata either way.
class VoiceLogSegments extends Table {
  TextColumn get id => text()();
  TextColumn get logId => text().references(VoiceLogs, #id)();
  IntColumn get segmentIndex => integer()();

  /// SQL column name stays `text`; the Dart getter is renamed to avoid
  /// colliding with `Table.text()` — same workaround used on
  /// EntityMentions.
  TextColumn get segmentText => text().named('text')();

  BlobColumn get embedding => blob()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}
