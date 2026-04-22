import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'schema/canonical_entities.dart';
import 'schema/entity_mentions.dart';
import 'schema/processing_jobs.dart';
import 'schema/voice_log_segments.dart';
import 'schema/voice_logs.dart';

part 'database.g.dart';

/// Local SQLite database backing VoxSynth.
///
/// Schema history:
/// - v1 (Phase 0): VoiceLogs, EntityMentions, CanonicalEntities,
///   ProcessingJobs + FTS5 virtual table.
/// - v2 (Phase 3): + VoiceLogSegments (blob embedding).
/// - v3 (Phase 5): CanonicalEntities gains an embedding blob for
///   similarity-based mention linking.
///
/// `sqlite-vec` virtual table for native vector search is deferred; the
/// Phase 3 retriever does brute-force cosine over the blob column in
/// memory. The segments table schema is compatible with that later
/// upgrade — embeddings move out, segment metadata stays.
@DriftDatabase(
  tables: [
    VoiceLogs,
    EntityMentions,
    CanonicalEntities,
    ProcessingJobs,
    VoiceLogSegments,
  ],
)
class VoxSynthDatabase extends _$VoxSynthDatabase {
  VoxSynthDatabase(super.e);

  @override
  int get schemaVersion => 3;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) async {
      await m.createAll();
      await customStatement(
        'CREATE VIRTUAL TABLE voice_logs_fts '
        'USING fts5(raw_transcript, cleaned_text)',
      );
    },
    onUpgrade: (m, from, to) async {
      if (from < 2) {
        await m.createTable(voiceLogSegments);
      }
      if (from < 3) {
        await m.addColumn(canonicalEntities, canonicalEntities.embedding);
      }
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
