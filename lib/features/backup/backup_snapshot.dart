import 'dart:io';

import 'package:drift/drift.dart';
import 'package:path/path.dart' as p;

import '../../core/db/database.dart';

/// Complete in-memory snapshot of every user-facing table plus a list of
/// audio files to bundle alongside. `processing_jobs` and FTS shadow
/// tables are intentionally omitted: jobs are derivable state, FTS gets
/// rebuilt from `voice_logs` content on import.
class BackupSnapshot {
  const BackupSnapshot({
    required this.schemaVersion,
    required this.exportedAt,
    required this.voiceLogs,
    required this.transcriptSegments,
    required this.entityMentions,
    required this.canonicalEntities,
    required this.voiceLogSegments,
    required this.memoryItems,
    required this.memorySources,
    required this.memoryEntityLinks,
    required this.memoryEmbeddings,
    required this.actionItems,
    required this.askThreads,
    required this.askMessages,
    required this.summaries,
    required this.audioFiles,
  });

  final int schemaVersion;
  final DateTime exportedAt;

  final List<Map<String, Object?>> voiceLogs;
  final List<Map<String, Object?>> transcriptSegments;
  final List<Map<String, Object?>> entityMentions;
  final List<Map<String, Object?>> canonicalEntities;
  final List<Map<String, Object?>> voiceLogSegments;
  final List<Map<String, Object?>> memoryItems;
  final List<Map<String, Object?>> memorySources;
  final List<Map<String, Object?>> memoryEntityLinks;
  final List<Map<String, Object?>> memoryEmbeddings;
  final List<Map<String, Object?>> actionItems;
  final List<Map<String, Object?>> askThreads;
  final List<Map<String, Object?>> askMessages;
  final List<Map<String, Object?>> summaries;

  /// Absolute paths of audio WAV files referenced by [voiceLogs] that
  /// exist on disk at snapshot time. Missing audio is silently dropped;
  /// the metadata row is still exported.
  final List<String> audioFiles;

  /// Manifest layout — JSON-encoded inside the encrypted ZIP. Keep keys
  /// in lockstep with `BackupApplier.apply`.
  Map<String, Object?> toManifestJson() => {
    'schema_version': schemaVersion,
    'exported_at': exportedAt.toIso8601String(),
    'tables': {
      'voice_logs': voiceLogs,
      'transcript_segments': transcriptSegments,
      'entity_mentions': entityMentions,
      'canonical_entities': canonicalEntities,
      'voice_log_segments': voiceLogSegments,
      'memory_items': memoryItems,
      'memory_sources': memorySources,
      'memory_entity_links': memoryEntityLinks,
      'memory_embeddings': memoryEmbeddings,
      'action_items': actionItems,
      'ask_threads': askThreads,
      'ask_messages': askMessages,
      'summaries': summaries,
    },
  };
}

/// Read every backup-eligible table out of [db] in a single transaction
/// and resolve audio file paths against [docsPath].
Future<BackupSnapshot> readSnapshot({
  required VoxSynthDatabase db,
  required String docsPath,
}) async {
  return db.transaction(() async {
    final voiceLogs = await db.select(db.voiceLogs).get();
    final audioFiles = <String>[];
    for (final log in voiceLogs) {
      final absolute = p.isAbsolute(log.audioPath)
          ? log.audioPath
          : p.join(docsPath, log.audioPath);
      if (File(absolute).existsSync()) {
        audioFiles.add(absolute);
      }
    }

    Future<List<Map<String, Object?>>> dump<R extends DataClass>(
      ResultSetImplementation<HasResultSet, R> table,
    ) async {
      final rows = await db.select(table).get();
      return rows.map((r) => r.toJson()).toList(growable: false);
    }

    return BackupSnapshot(
      schemaVersion: db.schemaVersion,
      exportedAt: DateTime.now().toUtc(),
      voiceLogs: voiceLogs.map((r) => r.toJson()).toList(growable: false),
      transcriptSegments: await dump(db.transcriptSegments),
      entityMentions: await dump(db.entityMentions),
      canonicalEntities: await dump(db.canonicalEntities),
      voiceLogSegments: await dump(db.voiceLogSegments),
      memoryItems: await dump(db.memoryItems),
      memorySources: await dump(db.memorySources),
      memoryEntityLinks: await dump(db.memoryEntityLinks),
      memoryEmbeddings: await dump(db.memoryEmbeddings),
      actionItems: await dump(db.actionItems),
      askThreads: await dump(db.askThreads),
      askMessages: await dump(db.askMessages),
      summaries: await dump(db.summaries),
      audioFiles: audioFiles,
    );
  });
}
