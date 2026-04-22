import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'schema/canonical_entities.dart';
import 'schema/entity_mentions.dart';
import 'schema/processing_jobs.dart';
import 'schema/voice_logs.dart';

part 'database.g.dart';

/// Local SQLite database backing VoxSynth. Schema version 1 — Phase 0
/// declares tables + the FTS5 virtual table only; no queries or DAOs until
/// Phase 2 wires the repository layer. The `sqlite-vec` virtual table for
/// 384-dim segment embeddings is deferred to Phase 3 (extension-loading
/// spike pending).
@DriftDatabase(
  tables: [VoiceLogs, EntityMentions, CanonicalEntities, ProcessingJobs],
)
class VoxSynthDatabase extends _$VoxSynthDatabase {
  VoxSynthDatabase(super.e);

  @override
  int get schemaVersion => 1;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) async {
      await m.createAll();
      // FTS5 index over raw + cleaned transcripts. Content-less —
      // the repository manually syncs rows on insert/update in a
      // later phase.
      await customStatement(
        'CREATE VIRTUAL TABLE voice_logs_fts '
        'USING fts5(raw_transcript, cleaned_text)',
      );
    },
  );
}

/// Opens the SQLite file at `<app docs>/voxsynth.sqlite` in a background
/// isolate. Callers typically wrap this in a Riverpod provider; Phase 0
/// leaves it dormant until Phase 2 wires the repository layer.
LazyDatabase openVoxSynthDatabase() {
  return LazyDatabase(() async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File(p.join(dir.path, 'voxsynth.sqlite'));
    return NativeDatabase.createInBackground(file);
  });
}
