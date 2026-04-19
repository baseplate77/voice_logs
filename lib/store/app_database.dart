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
@DriftDatabase(tables: [VoiceLogs, TranscriptChunks, Entities, ChunkEntities])
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.e);

  @override
  int get schemaVersion => 1;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          await m.createAll();
          await _createFtsTableAndTriggers(m);
        },
        onUpgrade: (m, from, to) async {
          // No upgrades yet. Future migrations append here.
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
