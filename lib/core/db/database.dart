import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;

import 'schema/canonical_entities.dart';
import 'schema/entity_mentions.dart';
import 'schema/memory_embeddings.dart';
import 'schema/memory_entity_links.dart';
import 'schema/memory_items.dart';
import 'schema/memory_sources.dart';
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
/// - v4 (Phase 5.5): + MemoryItems, MemorySources, MemoryEntityLinks,
///   MemoryEmbeddings + memory FTS5 virtual table.
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
    MemoryItems,
    MemorySources,
    MemoryEntityLinks,
    MemoryEmbeddings,
  ],
)
class VoxSynthDatabase extends _$VoxSynthDatabase {
  VoxSynthDatabase(super.e);

  @override
  int get schemaVersion => 4;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) async {
      await m.createAll();
      await customStatement(
        'CREATE VIRTUAL TABLE voice_logs_fts '
        'USING fts5(raw_transcript, cleaned_text)',
      );
      await customStatement(
        'CREATE VIRTUAL TABLE memory_items_fts '
        'USING fts5(text, normalized_text)',
      );
    },
    onUpgrade: (m, from, to) async {
      if (from < 2) {
        await m.createTable(voiceLogSegments);
      }
      if (from < 3) {
        await m.addColumn(canonicalEntities, canonicalEntities.embedding);
      }
      if (from < 4) {
        await m.createTable(memoryItems);
        await m.createTable(memorySources);
        await m.createTable(memoryEntityLinks);
        await m.createTable(memoryEmbeddings);
        await customStatement(
          'CREATE VIRTUAL TABLE IF NOT EXISTS memory_items_fts '
          'USING fts5(text, normalized_text)',
        );
      }
    },
  );
}

/// Opens the SQLite file at `<docsPath>/voxsynth.sqlite` in a background
/// isolate. The documents path is resolved once in `main()` and passed
/// through so drift's lazy opener never calls `path_provider` from
/// inside the first-frame build, which can race with Android plugin
/// attachment and throw `channel-error` on cold boot.
LazyDatabase openVoxSynthDatabase(String docsPath) {
  return LazyDatabase(() async {
    final file = File(p.join(docsPath, 'voxsynth.sqlite'));
    return NativeDatabase.createInBackground(file);
  });
}
