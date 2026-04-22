import 'package:drift/drift.dart';

import '../database.dart';

/// Helper for keeping the `voice_logs_fts` virtual table in sync with
/// the `voice_logs` table. Phase 3 calls [sync] after insertRecorded
/// and markRefined so the search path finds the log the moment it
/// lands.
class VoiceLogFts {
  VoiceLogFts(this._db);

  final VoxSynthDatabase _db;

  /// Re-insert the FTS row for [logId]. Idempotent — deletes the
  /// existing row (if any) and inserts the current content. FTS5 virtual
  /// tables don't support UPSERT, so we delete+insert in two statements.
  Future<void> sync(String logId) async {
    final log = await (_db.select(
      _db.voiceLogs,
    )..where((t) => t.id.equals(logId))).getSingleOrNull();
    if (log == null) return;
    final rowid = await _findRowid(logId);
    if (rowid == null) return;
    await _db.customStatement('DELETE FROM voice_logs_fts WHERE rowid = ?', [
      rowid,
    ]);
    await _db.customStatement(
      'INSERT INTO voice_logs_fts(rowid, raw_transcript, cleaned_text) '
      'VALUES (?, ?, ?)',
      [rowid, log.rawTranscript, log.cleanedText ?? ''],
    );
  }

  /// Drop the FTS row for [logId] if one exists.
  Future<void> remove(String logId) async {
    final rowid = await _findRowid(logId);
    if (rowid == null) return;
    await _db.customStatement('DELETE FROM voice_logs_fts WHERE rowid = ?', [
      rowid,
    ]);
  }

  Future<int?> _findRowid(String logId) async {
    final rows = await _db
        .customSelect(
          'SELECT rowid FROM voice_logs WHERE id = ?',
          variables: [Variable<String>(logId)],
        )
        .get();
    if (rows.isEmpty) return null;
    return rows.first.read<int>('rowid');
  }
}
