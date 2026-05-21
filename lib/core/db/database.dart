import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;

import 'schema/action_items.dart';
import 'schema/ask_messages.dart';
import 'schema/ask_threads.dart';
import 'schema/canonical_entities.dart';
import 'schema/entity_mentions.dart';
import 'schema/entity_summaries.dart';
import 'schema/memory_embeddings.dart';
import 'schema/memory_entity_links.dart';
import 'schema/memory_items.dart';
import 'schema/memory_sources.dart';
import 'schema/processing_jobs.dart';
// ignore: unused_import, used by Drift's annotation/code generator.
import 'schema/prompt_suggestions.dart';
import 'schema/summaries.dart';
import 'schema/transcript_segments.dart';
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
/// - v5 (Phase 9.0): + TranscriptSegments, Summaries (+ summaries_fts).
///   VoiceLogSegments gains enrichment columns. MemoryItems gains
///   importance_score.
/// - v6 (Phase 5.5/6 extension): + ActionItems for extracted tasks,
///   reminders, decisions, and follow-ups.
/// - v7 (Phase 9 — synced playback): TranscriptSegments gains
///   `word_timings_json` for per-word Parakeet timestamps. Migration is a
///   destructive drop-and-recreate while the app is still in pre-release.
/// - v8 (Phase 11 — templates, reverted in v9): briefly added `template_id`
///   on VoiceLogs. Feature was pulled before any meaningful data shipped.
/// - v9 (Phase 11 cleanup): drops the unused `template_id` column. Same
///   destructive auto-wipe as v7/v8.
/// - v10: VoiceLogs gains nullable `title` for Gemma-generated log titles.
/// - v11: + AskThreads and AskMessages for persisted Ask Journal history.
///   Last destructive bump — pre-v11 databases are still wiped on upgrade.
/// - v12: + PromptSuggestions for tap-to-ask chips extracted per log.
///   First additive bump — existing data (voice logs, memories, Ask threads,
///   etc.) survives the upgrade.
/// - v13: + EntitySummaries — Gemma-generated relationship/context blurbs
///   for canonical entities. Additive.
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
    TranscriptSegments,
    Summaries,
    ActionItems,
    AskThreads,
    AskMessages,
    PromptSuggestions,
    EntitySummaries,
  ],
)
class VoxSynthDatabase extends _$VoxSynthDatabase {
  VoxSynthDatabase(super.e);

  @override
  int get schemaVersion => 15;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) async {
      await m.createAll();
      await _createFtsTables();
    },
    onUpgrade: (m, from, to) async {
      // Pre-v11 databases are still wiped destructively — the schema
      // history before that point churned columns/types too aggressively
      // for a column-by-column path to be worth maintaining. From v11 on
      // we add only what's new so chat threads, voice logs, memories, and
      // their FTS indexes survive every bump.
      if (from < 11) {
        await _dropEverything();
        await m.createAll();
        await _createFtsTables();
        return;
      }
      if (from < 12) {
        await m.createTable(promptSuggestions);
      }
      if (from < 13) {
        await m.createTable(entitySummaries);
      }
      if (from < 14) {
        await m.addColumn(entitySummaries, entitySummaries.structuredFacts);
      }
      if (from < 15) {
        await m.addColumn(voiceLogs, voiceLogs.flowerType);
      }
    },
  );

  Future<void> _createFtsTables() async {
    await customStatement(
      'CREATE VIRTUAL TABLE voice_logs_fts '
      'USING fts5(raw_transcript, cleaned_text, title)',
    );
    await customStatement(
      'CREATE VIRTUAL TABLE memory_items_fts '
      'USING fts5(text, normalized_text)',
    );
    await customStatement(
      'CREATE VIRTUAL TABLE summaries_fts '
      'USING fts5(title, body)',
    );
  }

  Future<void> _dropEverything() async {
    // FTS virtual tables first — they reference the base tables.
    const dropStatements = <String>[
      'DROP TABLE IF EXISTS voice_logs_fts',
      'DROP TABLE IF EXISTS memory_items_fts',
      'DROP TABLE IF EXISTS summaries_fts',
      'DROP TABLE IF EXISTS entity_summaries',
      'DROP TABLE IF EXISTS prompt_suggestions',
      'DROP TABLE IF EXISTS ask_messages',
      'DROP TABLE IF EXISTS ask_threads',
      'DROP TABLE IF EXISTS action_items',
      'DROP TABLE IF EXISTS summaries',
      'DROP TABLE IF EXISTS transcript_segments',
      'DROP TABLE IF EXISTS memory_embeddings',
      'DROP TABLE IF EXISTS memory_entity_links',
      'DROP TABLE IF EXISTS memory_sources',
      'DROP TABLE IF EXISTS memory_items',
      'DROP TABLE IF EXISTS voice_log_segments',
      'DROP TABLE IF EXISTS processing_jobs',
      'DROP TABLE IF EXISTS entity_mentions',
      'DROP TABLE IF EXISTS canonical_entities',
      'DROP TABLE IF EXISTS voice_logs',
    ];
    for (final stmt in dropStatements) {
      await customStatement(stmt);
    }
  }
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
