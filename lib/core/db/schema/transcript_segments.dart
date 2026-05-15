import 'package:drift/drift.dart';

import 'voice_logs.dart';

/// Timestamped segments from STT output. Populated during transcription
/// when the recognizer provides per-word or per-phrase timing.
class TranscriptSegments extends Table {
  TextColumn get id => text()();
  TextColumn get logId => text().references(VoiceLogs, #id)();
  IntColumn get startTimeMs => integer()();
  IntColumn get endTimeMs => integer()();
  TextColumn get segmentText => text().named('text')();
  RealColumn get confidence => real().nullable()();
  IntColumn get createdAt => integer()();

  /// JSON-encoded list of `{word, startMs, endMs}` entries for this segment.
  /// Null when the recognizer did not provide per-word timing.
  TextColumn get wordTimingsJson =>
      text().named('word_timings_json').nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}
