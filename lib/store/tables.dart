import 'package:drift/drift.dart';

/// One recorded voice-log session. 1:1 with a [RecordingHandle] from
/// capture (Phase 1).
@DataClassName('VoiceLogRow')
class VoiceLogs extends Table {
  /// Session id — the same UUID `RecordingHandle.id` carried.
  TextColumn get id => text()();

  /// Wall-clock at recording start, ms since epoch.
  IntColumn get startedAt => integer()();

  /// Total audio length in ms. Computed by the capture service on stop.
  IntColumn get durationMs => integer()();

  /// Absolute path to the WAV file on local disk. Phase 1 writes this
  /// into the app's tmp/documents directory; deletion cascades remove it.
  TextColumn get audioPath => text()();

  /// Pre-cleanup ASR output (Phase 2). Null when the cleanup pipeline
  /// ran directly on raw segment transcripts instead of a full
  /// recording-level transcript.
  TextColumn get rawTranscript => text().nullable()();

  /// Post-cleanup text (Phase 3). Same thing as
  /// `CleanedTranscript.text`.
  TextColumn get cleanedTranscript => text()();

  /// Free-form tag applied by the user ("standup", "1:1", "research"…).
  /// Null by default; UI can set it later.
  TextColumn get sourceTag => text().nullable()();

  /// BCP-47-ish language code ("en", "hi"). Populated from
  /// `Transcript.detectedLanguage`.
  TextColumn get language => text().withDefault(const Constant('en'))();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// A semantic chunk within a [VoiceLogs] row — Phase 3's
/// [TopicChunk] persisted. The Phase 4 vector index (ObjectBox) stores
/// one [ChunkVector] per row, correlated by [objectboxId].
///
/// Named `TranscriptChunks` / `transcript_chunks` on both sides
/// (rather than the shorter `Chunks` / `chunks`) because drift 2.x
/// silently skips code generation for a table whose SQL name collides
/// with a reserved symbol in its generated lookup map. The FTS5 table
/// + triggers in `app_database.dart` reference `transcript_chunks` too.
@DataClassName('ChunkRow')
class TranscriptChunks extends Table {

  /// Auto-increment integer; matches what we'll pass to ObjectBox as the
  /// vector id so a single lookup bridges both stores.
  IntColumn get id => integer().autoIncrement()();

  /// Parent recording.
  TextColumn get logId => text().references(VoiceLogs, #id)();

  /// The chunk text (cleaned). Column is named `content` rather than
  /// `text` because `text` shadows drift's column-factory function
  /// `text()` inside the class scope, which causes drift_dev to
  /// silently skip code generation for the whole table.
  TextColumn get content => text()();

  /// Character range inside `voice_logs.cleaned_transcript`. Matches
  /// `TopicChunk.startChar` / `endChar`.
  IntColumn get startChar => integer()();
  IntColumn get endChar => integer()();

  /// LLM-assigned topic label (or `(fixed-width fallback)` when the
  /// chunker had to fall back).
  TextColumn get topicHint => text()();

  /// Optional cluster id set by Phase 7's weekly themes job. Null until
  /// that phase populates it.
  IntColumn get topicClusterId => integer().nullable()();

  /// ms since epoch; set to `voice_logs.started_at` by convention.
  IntColumn get createdAt => integer()();

  /// ObjectBox row id for the chunk's embedding vector. 0 = no vector
  /// stored yet. Populated in Phase 4c.
  IntColumn get objectboxId => integer().withDefault(const Constant(0))();
}

/// Deduplicated entities seen across all recordings. Same semantic as
/// the Phase 3 [Entity] type but persisted.
@DataClassName('EntityRow')
class Entities extends Table {
  IntColumn get id => integer().autoIncrement()();

  /// Lowercase canonical form for `person`/`project`/`concept`;
  /// Title-Case for `organization`. Matches `Entity.name`.
  TextColumn get canonicalName => text()();

  /// Phase 3's open-enum kind. Stored as text so widening the enum
  /// later doesn't need a migration.
  TextColumn get kind => text()();

  /// JSON-encoded list of alias surface forms. Loaded as
  /// `List<String>` at the repo boundary.
  TextColumn get aliasesJson => text().withDefault(const Constant('[]'))();

  /// ms-since-epoch of the first recording that mentioned this entity.
  IntColumn get firstSeen => integer()();

  /// ms-since-epoch of the most recent recording. Updated on every
  /// ingest that touches this entity.
  IntColumn get lastSeen => integer()();
}

/// Many-to-many join of chunks ↔ entities — each row = "this entity
/// was mentioned in this chunk". Drives Phase 5 entity-weighted
/// retrieval.
@DataClassName('ChunkEntityRow')
class ChunkEntities extends Table {
  IntColumn get chunkId => integer().references(TranscriptChunks, #id)();
  IntColumn get entityId => integer().references(Entities, #id)();

  @override
  Set<Column<Object>> get primaryKey => {chunkId, entityId};
}
