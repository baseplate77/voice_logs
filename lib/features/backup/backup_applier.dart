import 'dart:io';

import 'package:drift/drift.dart';
import 'package:path/path.dart' as p;

import '../../core/db/database.dart';
import '../../core/db/repositories/voice_log_fts.dart';
import 'backup_reader.dart';

/// Per-table counts surfaced to the import screen. `inserted` rows are
/// net-new on this device, `skipped` are rows whose primary key already
/// existed (merge-by-id chosen during import design).
class ApplyCount {
  const ApplyCount({required this.inserted, required this.skipped});
  final int inserted;
  final int skipped;
}

/// Aggregate report returned by [applyBackup].
class BackupApplyReport {
  const BackupApplyReport({
    required this.tableCounts,
    required this.audioFilesRestored,
    required this.voiceLogsInDbAfter,
  });

  final Map<String, ApplyCount> tableCounts;
  final int audioFilesRestored;

  /// Total number of `voice_logs` rows in the destination DB after the
  /// merge completes — surfaced to the import screen so the user can
  /// see the truth-from-the-DB count alongside the per-table inserts.
  /// If this is 0 with a non-zero `totalInserted`, something went wrong
  /// at the storage layer.
  final int voiceLogsInDbAfter;

  int get totalInserted =>
      tableCounts.values.fold(0, (sum, c) => sum + c.inserted);
  int get totalSkipped =>
      tableCounts.values.fold(0, (sum, c) => sum + c.skipped);
}

/// Apply a [DecodedBackup] to [db], merging by each table's primary key
/// and skipping rows that already exist. Audio files are written into
/// `<docsPath>/audio/` (matching the recording flow's layout).
///
/// Refuses to apply backups from a future schema version — newer tables
/// might have columns this build can't write.
Future<BackupApplyReport> applyBackup({
  required DecodedBackup backup,
  required VoxSynthDatabase db,
  required String docsPath,
}) async {
  final manifest = backup.manifest;
  final backupSchemaVersion = manifest['schema_version'] as int? ?? 0;
  if (backupSchemaVersion > db.schemaVersion) {
    throw BackupApplyError(
      'Backup uses schema v$backupSchemaVersion which is newer than this '
      'app (v${db.schemaVersion}). Update the app and try again.',
    );
  }

  final tables = (manifest['tables'] as Map<String, Object?>?) ?? {};
  final counts = <String, ApplyCount>{};
  final voiceLogJsonRows = _list(tables['voice_logs']);
  final memoryItemJsonRows = _list(tables['memory_items']);

  await db.transaction(() async {
    counts['voice_logs'] = await _applyRows(
      db,
      db.voiceLogs,
      voiceLogJsonRows,
      VoiceLog.fromJson,
    );
    counts['canonical_entities'] = await _applyRows(
      db,
      db.canonicalEntities,
      _list(tables['canonical_entities']),
      CanonicalEntity.fromJson,
    );
    counts['entity_mentions'] = await _applyRows(
      db,
      db.entityMentions,
      _list(tables['entity_mentions']),
      EntityMention.fromJson,
    );
    counts['voice_log_segments'] = await _applyRows(
      db,
      db.voiceLogSegments,
      _list(tables['voice_log_segments']),
      VoiceLogSegment.fromJson,
    );
    counts['transcript_segments'] = await _applyRows(
      db,
      db.transcriptSegments,
      _list(tables['transcript_segments']),
      TranscriptSegment.fromJson,
    );
    counts['memory_items'] = await _applyRows(
      db,
      db.memoryItems,
      memoryItemJsonRows,
      MemoryItem.fromJson,
    );
    counts['memory_sources'] = await _applyRows(
      db,
      db.memorySources,
      _list(tables['memory_sources']),
      MemorySource.fromJson,
    );
    counts['memory_entity_links'] = await _applyRows(
      db,
      db.memoryEntityLinks,
      _list(tables['memory_entity_links']),
      MemoryEntityLink.fromJson,
    );
    counts['memory_embeddings'] = await _applyRows(
      db,
      db.memoryEmbeddings,
      _list(tables['memory_embeddings']),
      MemoryEmbedding.fromJson,
    );
    counts['action_items'] = await _applyRows(
      db,
      db.actionItems,
      _list(tables['action_items']),
      ActionItem.fromJson,
    );
    counts['ask_threads'] = await _applyRows(
      db,
      db.askThreads,
      _list(tables['ask_threads']),
      AskThread.fromJson,
    );
    counts['ask_messages'] = await _applyRows(
      db,
      db.askMessages,
      _list(tables['ask_messages']),
      AskMessage.fromJson,
    );
    counts['summaries'] = await _applyRows(
      db,
      db.summaries,
      _list(tables['summaries']),
      Summary.fromJson,
    );
  });

  // FTS shadow tables don't auto-populate when rows are inserted via the
  // typed API; the recording flow normally calls VoiceLogFts.sync after
  // every insertRecorded. Mirror that here so imported logs are findable
  // by keyword search and so any FTS-derived UI re-emits.
  final fts = VoiceLogFts(db);
  for (final row in voiceLogJsonRows) {
    final id = row['id'];
    if (id is String) {
      await fts.sync(id);
    }
  }
  await _rebuildMemoryItemsFts(db, memoryItemJsonRows);

  final audioDir = Directory(p.join(docsPath, 'audio'));
  if (!audioDir.existsSync()) audioDir.createSync(recursive: true);
  var audioRestored = 0;
  backup.audioBytes.forEach((filename, bytes) {
    final dest = File(p.join(audioDir.path, filename));
    if (dest.existsSync()) return; // merge-by-id: skip existing audio.
    dest.writeAsBytesSync(bytes);
    audioRestored++;
  });

  final voiceLogsInDb = await _rowCount(db, 'voice_logs');

  return BackupApplyReport(
    tableCounts: counts,
    audioFilesRestored: audioRestored,
    voiceLogsInDbAfter: voiceLogsInDb,
  );
}

/// Mirror memory_repository's FTS-sync logic for newly imported memory
/// rows. Without this, imported memories don't surface in Ask retrieval
/// or in the memory screen's search field.
Future<void> _rebuildMemoryItemsFts(
  VoxSynthDatabase db,
  List<Map<String, Object?>> rows,
) async {
  for (final row in rows) {
    final id = row['id'];
    if (id is! String) continue;
    final rowidRow = await db
        .customSelect(
          'SELECT rowid, text, normalized_text FROM memory_items WHERE id = ?',
          variables: [Variable<String>(id)],
        )
        .getSingleOrNull();
    if (rowidRow == null) continue;
    final rowid = rowidRow.read<int>('rowid');
    await db.customStatement('DELETE FROM memory_items_fts WHERE rowid = ?', [
      rowid,
    ]);
    await db.customStatement(
      'INSERT INTO memory_items_fts(rowid, text, normalized_text) VALUES (?, ?, ?)',
      [
        rowid,
        rowidRow.read<String>('text'),
        rowidRow.read<String>('normalized_text'),
      ],
    );
  }
}

/// Insert every row in [jsonRows] whose primary key isn't already in
/// [table]. drift's `InsertMode.insertOrIgnore` lets sqlite enforce
/// uniqueness without us tracking ids by hand. Inserted vs skipped is
/// derived from a row-count delta because `insertOrIgnore`'s return
/// value is `last_insert_rowid()` either way and can't be relied on.
Future<ApplyCount> _applyRows<T extends Table, R extends DataClass>(
  VoxSynthDatabase db,
  TableInfo<T, R> table,
  List<Map<String, Object?>> jsonRows,
  R Function(Map<String, Object?>) fromJson,
) async {
  if (jsonRows.isEmpty) return const ApplyCount(inserted: 0, skipped: 0);
  final before = await _rowCount(db, table.actualTableName);
  for (final json in jsonRows) {
    final R record;
    try {
      record = fromJson(json);
    } on Object {
      // Row has fields this build doesn't understand — older app reading
      // a newer backup. Falls through to the row-count delta below as a
      // skipped row rather than crashing the import.
      continue;
    }
    await db
        .into(table)
        .insert(record as Insertable<R>, mode: InsertMode.insertOrIgnore);
  }
  final after = await _rowCount(db, table.actualTableName);
  final inserted = after - before;
  // Anything that wasn't actually inserted — duplicate ids or malformed
  // rows — counts as skipped from the user's perspective.
  final skipped = jsonRows.length - inserted;
  return ApplyCount(inserted: inserted, skipped: skipped);
}

Future<int> _rowCount(VoxSynthDatabase db, String tableName) async {
  final row = await db
      .customSelect('SELECT COUNT(*) AS c FROM $tableName')
      .getSingle();
  return row.read<int>('c');
}

List<Map<String, Object?>> _list(Object? raw) {
  if (raw is! List) return const [];
  return raw
      .whereType<Map<dynamic, dynamic>>()
      .map((m) => m.cast<String, Object?>())
      .toList(growable: false);
}

/// Thrown for non-crypto apply failures — schema mismatch, malformed
/// table data, IO errors writing audio back to disk.
class BackupApplyError implements Exception {
  const BackupApplyError(this.message);
  final String message;
  @override
  String toString() => 'BackupApplyError: $message';
}
