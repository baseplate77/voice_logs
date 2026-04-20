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

/// Output of one Phase 7 background-synthesis job — a daily brief, a
/// weekly themes roll-up, or a monthly shift digest.
///
/// Stored as an opaque JSON payload so the schema doesn't need a
/// migration every time the job output evolves. The `kind` column
/// picks the payload's type; see `lib/synth/background/models/` for
/// the freezed classes each kind deserialises into.
@DataClassName('SynthesisRow')
class Syntheses extends Table {
  IntColumn get id => integer().autoIncrement()();

  /// One of the [SynthesisKind] string values — 'daily_brief',
  /// 'weekly_themes', 'monthly_shifts'. Stored as text so future jobs
  /// can widen the set without a schema migration.
  TextColumn get kind => text()();

  /// Inclusive ms-since-epoch bounds of the time range this synthesis
  /// summarises. Used by [MonthlyShiftsJob] to find the prior-period
  /// synthesis to diff against.
  IntColumn get periodStart => integer()();
  IntColumn get periodEnd => integer()();

  /// Serialised payload. Parsed via the matching freezed fromJson on
  /// read; callers must not poke at this raw JSON.
  TextColumn get payloadJson => text()();

  /// ms-since-epoch at which the job produced this row. Jobs are
  /// idempotent so duplicates on retry are harmless but visible here.
  IntColumn get createdAt => integer()();
}

/// One distilled memory row — Phase 8's semantic layer on top of
/// chunks/entities. Four kinds share this table (fact, decision,
/// episode, goal); kind-specific fields hang off nullable columns.
///
/// Named `memory` / `memories` per the plan. `id` is a TEXT UUID so
/// supersedence links can be inserted before the replacement row
/// commits (vs. an autoincrement that'd need a second round trip).
@DataClassName('MemoryRow')
class Memories extends Table {
  /// UUID / ULID assigned by the repository before insert.
  TextColumn get id => text()();

  /// One of `fact` | `decision` | `episode` | `goal`. Stored as text
  /// so future kinds can widen the enum without a schema migration.
  TextColumn get kind => text()();

  /// ~10-word retrieval-friendly handle. Indexed in FTS.
  TextColumn get title => text()();

  /// 1–3 sentence canonical phrasing. Also FTS-indexed. Column is
  /// named `body` (not `content`) because the FTS5 table below uses
  /// `content='memories'` which would shadow a same-named column.
  TextColumn get body => text()();

  /// `active` | `superseded` | `resolved` | `archived`.
  TextColumn get status => text().withDefault(const Constant('active'))();

  /// Extractor-assigned confidence, in [0, 1].
  RealColumn get confidence => real()();

  IntColumn get createdAt => integer()();
  IntColumn get updatedAt => integer()();

  /// When `status = superseded`, points to the replacement memory id.
  TextColumn get supersededById => text().nullable()();

  /// When did the memorable event happen — populated for decisions /
  /// episodes, null for facts and goals.
  IntColumn get occurredAt => integer().nullable()();

  /// Goal-only. ms-since-epoch target date.
  IntColumn get dueAt => integer().nullable()();

  /// Goal-only. `open` | `in_progress` | `done` | `abandoned`.
  TextColumn get goalState => text().nullable()();

  /// ObjectBox row id for the memory's embedding vector. 0 = no
  /// vector stored yet.
  IntColumn get objectboxId =>
      integer().withDefault(const Constant(0))();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// Join table linking a memory to the transcript chunks it was
/// extracted from. Provenance is first-class — UI can surface "this
/// memory came from recording X".
@DataClassName('MemorySourceRow')
class MemorySources extends Table {
  TextColumn get memoryId => text().references(Memories, #id)();

  /// Matches `transcript_chunks.id`.
  IntColumn get chunkId => integer().references(TranscriptChunks, #id)();

  /// How strongly this chunk supported the memory (0..1). The
  /// extractor sets it from text-overlap length; consolidator updates
  /// on merge.
  RealColumn get weight => real().withDefault(const Constant(1.0))();

  @override
  Set<Column<Object>> get primaryKey => {memoryId, chunkId};
}

/// Join table linking a memory to known canonical entities.
@DataClassName('MemoryEntityRow')
class MemoryEntities extends Table {
  TextColumn get memoryId => text().references(Memories, #id)();
  IntColumn get entityId => integer().references(Entities, #id)();

  @override
  Set<Column<Object>> get primaryKey => {memoryId, entityId};
}

/// Single-row cache of the always-on "about me" summary. Rebuilt
/// lazily by [ProfileBuilder] whenever [isStale] == 1.
@DataClassName('ProfileSummaryRow')
class ProfileSummaries extends Table {
  /// Always row id 1; we only keep one summary at a time.
  IntColumn get id => integer()();

  TextColumn get summary => text().withDefault(const Constant(''))();
  IntColumn get updatedAt => integer()();

  /// JSON array of memory ids whose content contributed to the current
  /// summary. Stored as JSON so the schema doesn't bloat with a join.
  TextColumn get sourceMemoryIdsJson =>
      text().withDefault(const Constant('[]'))();

  /// 1 when the next `current()` call should rebuild. Phase 8 jobs and
  /// the ingestion coordinator set this.
  IntColumn get isStale => integer().withDefault(const Constant(0))();

  @override
  Set<Column<Object>> get primaryKey => {id};
}
