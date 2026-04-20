import 'package:drift/drift.dart';

import 'tables.dart';

part 'app_database.g.dart';

/// VoxSynth's on-disk store.
///
/// Owns four Drift-managed tables (voice_logs, chunks, entities,
/// chunk_entities) plus an FTS5 virtual table `transcript_chunks_fts` that
/// mirrors `chunks.text` via insert/update/delete triggers.
///
/// FTS5 is declared via raw SQL in `onCreate` because Drift 2.x
/// generates virtual-table DDL for standard cases (no trigger
/// scaffolding) and we want the content-table mirror pattern.
///
/// Construct via [AppDatabase.connect] from the companion
/// `database_factory.dart` — that's where the SQLCipher key handshake
/// lives.
@DriftDatabase(tables: [
  VoiceLogs,
  TranscriptChunks,
  Entities,
  ChunkEntities,
  Syntheses,
  Memories,
  MemorySources,
  MemoryEntities,
  ProfileSummaries,
])
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.e);

  @override
  int get schemaVersion => 3;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          await m.createAll();
          await _createFtsTableAndTriggers(m);
          await _createMemoryFtsTableAndTriggers(m);
          await _seedProfileSummary(m);
        },
        onUpgrade: (m, from, to) async {
          // v1 → v2: Phase 7 adds the syntheses table. Its rows are
          // produced only by background jobs so there's no backfill;
          // a fresh empty table is the correct initial state.
          if (from < 2) {
            await m.createTable(syntheses);
          }
          // v2 → v3: Phase 8 adds the memory tables + FTS mirror +
          // single-row profile cache. No backfill — memories are
          // produced fresh by future ingests; old recordings can be
          // re-processed on demand.
          if (from < 3) {
            await m.createTable(memories);
            await m.createTable(memorySources);
            await m.createTable(memoryEntities);
            await m.createTable(profileSummaries);
            await _createMemoryFtsTableAndTriggers(m);
            await _seedProfileSummary(m);
          }
        },
      );

  Future<void> _createFtsTableAndTriggers(Migrator m) async {
    // `content='chunks'` + `content_rowid='id'` tells FTS5 we're
    // shadowing the `chunks` table; triggers below keep them in sync.
    // `unicode61 remove_diacritics 2` is the tokenizer the plan calls
    // for so Hindi/Marathi queries stay matchable after an NFC
    // round-trip. It also lowercases Latin text for English/Hinglish.
    await m.database.customStatement('''
      CREATE VIRTUAL TABLE transcript_chunks_fts USING fts5(
        content,
        content='transcript_chunks',
        content_rowid='id',
        tokenize='unicode61 remove_diacritics 2'
      )
    ''');
    await m.database.customStatement('''
      CREATE TRIGGER chunks_ai AFTER INSERT ON transcript_chunks BEGIN
        INSERT INTO transcript_chunks_fts(rowid, content) VALUES (new.id, new.content);
      END
    ''');
    await m.database.customStatement('''
      CREATE TRIGGER chunks_ad AFTER DELETE ON transcript_chunks BEGIN
        INSERT INTO transcript_chunks_fts(transcript_chunks_fts, rowid, content)
          VALUES ('delete', old.id, old.content);
      END
    ''');
    await m.database.customStatement('''
      CREATE TRIGGER chunks_au AFTER UPDATE ON transcript_chunks BEGIN
        INSERT INTO transcript_chunks_fts(transcript_chunks_fts, rowid, content)
          VALUES ('delete', old.id, old.content);
        INSERT INTO transcript_chunks_fts(rowid, content) VALUES (new.id, new.content);
      END
    ''');
  }

  /// Build the memories FTS5 mirror + sync triggers, parallel to the
  /// chunks FTS wiring above. The rowid mirrors `memories.rowid`
  /// (SQLite auto-rowid), and we carry both `title` and `body` so a
  /// query can match either.
  Future<void> _createMemoryFtsTableAndTriggers(Migrator m) async {
    await m.database.customStatement('''
      CREATE VIRTUAL TABLE memories_fts USING fts5(
        title,
        body,
        content='memories',
        content_rowid='rowid',
        tokenize='unicode61 remove_diacritics 2'
      )
    ''');
    await m.database.customStatement('''
      CREATE TRIGGER memories_ai AFTER INSERT ON memories BEGIN
        INSERT INTO memories_fts(rowid, title, body)
          VALUES (new.rowid, new.title, new.body);
      END
    ''');
    await m.database.customStatement('''
      CREATE TRIGGER memories_ad AFTER DELETE ON memories BEGIN
        INSERT INTO memories_fts(memories_fts, rowid, title, body)
          VALUES ('delete', old.rowid, old.title, old.body);
      END
    ''');
    await m.database.customStatement('''
      CREATE TRIGGER memories_au AFTER UPDATE ON memories BEGIN
        INSERT INTO memories_fts(memories_fts, rowid, title, body)
          VALUES ('delete', old.rowid, old.title, old.body);
        INSERT INTO memories_fts(rowid, title, body)
          VALUES (new.rowid, new.title, new.body);
      END
    ''');
  }

  /// Insert the singleton profile_summary row (id=1). Always present;
  /// [ProfileBuilder] toggles [isStale] + updates text in-place.
  Future<void> _seedProfileSummary(Migrator m) async {
    await m.database.customStatement(
      '''
      INSERT OR IGNORE INTO profile_summaries
        (id, summary, updated_at, source_memory_ids_json, is_stale)
      VALUES (1, '', 0, '[]', 0)
      ''',
    );
  }

  /// BM25-ranked keyword search over `memories_fts`. Returns memory
  /// ids (TEXT) ordered best-first.
  Future<List<String>> searchMemoryIds(
    String query, {
    int limit = 20,
    List<String>? statuses,
  }) async {
    // FTS5 rowid is the hidden auto-rowid of `memories`; we join back
    // through that to pull `memories.id` (TEXT). Optional status
    // filter keeps archived/superseded rows out of default retrieval.
    final statusPredicate = (statuses == null || statuses.isEmpty)
        ? ''
        : 'AND m.status IN (${List.filled(statuses.length, '?').join(', ')})';
    final vars = <Variable<Object>>[
      Variable.withString(query),
      if (statuses != null)
        for (final s in statuses) Variable.withString(s),
      Variable.withInt(limit),
    ];
    final rows = await customSelect(
      '''
      SELECT m.id AS memory_id
      FROM memories_fts f
      JOIN memories m ON m.rowid = f.rowid
      WHERE memories_fts MATCH ?
      $statusPredicate
      ORDER BY bm25(memories_fts)
      LIMIT ?
      ''',
      variables: vars,
    ).get();
    return rows
        .map((r) => r.read<String>('memory_id'))
        .toList(growable: false);
  }

  /// BM25-ranked keyword search over [transcript_chunks_fts]. Returns chunk ids
  /// ordered best-first; the repository layer widens these into full
  /// [ChunkRow]s.
  Future<List<int>> searchChunkIds(String query, {int limit = 20}) async {
    // `MATCH ?` with FTS5 — the query syntax supports quoted phrases,
    // prefix `*`, NEAR, etc. The repo layer cleans/escapes input before
    // it gets here.
    final rows = await customSelect(
      '''
      SELECT rowid AS chunk_id
      FROM transcript_chunks_fts
      WHERE transcript_chunks_fts MATCH ?
      ORDER BY bm25(transcript_chunks_fts)
      LIMIT ?
      ''',
      variables: [Variable.withString(query), Variable.withInt(limit)],
    ).get();
    return rows.map((r) => r.read<int>('chunk_id')).toList(growable: false);
  }
}
