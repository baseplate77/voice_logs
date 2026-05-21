import 'package:drift/drift.dart';

/// One row per recorded voice log. [processingState] drives the background
/// pipeline state machine: `recorded` → `refined` → `embedded` (terminal
/// happy path), or `failed` on any error.
class VoiceLogs extends Table {
  /// UUID v4.
  TextColumn get id => text()();

  /// Unix milliseconds at the moment recording stopped.
  IntColumn get createdAt => integer()();

  /// Duration of the recorded audio in milliseconds.
  IntColumn get durationMs => integer()();

  /// Path to the audio file, relative to the app documents directory.
  TextColumn get audioPath => text()();

  /// Raw transcript from Parakeet, available immediately on stop.
  TextColumn get rawTranscript => text()();

  /// Cleaned transcript from Gemma. `NULL` until the refine job completes.
  TextColumn get cleanedText => text().nullable()();

  /// Short user-facing title from Gemma. `NULL` until the refine job completes.
  TextColumn get title => text().nullable()();

  /// One of: `recorded` | `refined` | `embedded` | `failed`.
  TextColumn get processingState => text()();

  /// Last-error message if [processingState] is `failed`.
  TextColumn get errorMessage => text().nullable()();

  /// The emotional plant category extracted by Gemma: e.g. sakura, lavender, cactus, etc.
  TextColumn get flowerType => text().nullable()();

  /// Number of times a pipeline stage has been retried for this log.
  IntColumn get retryCount => integer().withDefault(const Constant(0))();

  @override
  Set<Column<Object>> get primaryKey => {id};
}
