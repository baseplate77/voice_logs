import 'package:drift/drift.dart';

import '../../app_error.dart';
import '../../result.dart';
import '../database.dart';
import '../processing_state.dart';
import 'voice_log_fts.dart';

/// Data-transfer view of a voice log consumed by the UI. Keeps feature
/// code from importing drift's row classes directly.
class VoiceLogView {
  const VoiceLogView({
    required this.id,
    required this.createdAt,
    required this.durationMs,
    required this.audioPath,
    required this.rawTranscript,
    required this.cleanedText,
    required this.title,
    required this.processingState,
    required this.errorMessage,
    this.flowerType,
  });

  final String id;
  final DateTime createdAt;
  final int durationMs;
  final String audioPath;
  final String rawTranscript;
  final String? cleanedText;
  final String? title;
  final ProcessingState processingState;
  final String? errorMessage;
  final String? flowerType;

  /// The user-visible transcript for this log — prefers the Gemma-cleaned
  /// version and falls back to the raw transcript.
  String get displayText => cleanedText ?? rawTranscript;

  /// Short title shown in log lists. Falls back to transcript text while
  /// the refine job is still running or if title generation failed.
  String get displayTitle {
    final trimmed = title?.trim();
    if (trimmed != null && trimmed.isNotEmpty) return trimmed;
    return displayText;
  }

  factory VoiceLogView.fromRow(VoiceLog row) {
    return VoiceLogView(
      id: row.id,
      createdAt: DateTime.fromMillisecondsSinceEpoch(row.createdAt),
      durationMs: row.durationMs,
      audioPath: row.audioPath,
      rawTranscript: row.rawTranscript,
      cleanedText: row.cleanedText,
      title: row.title,
      processingState: ProcessingState.fromWire(row.processingState),
      errorMessage: row.errorMessage,
      flowerType: row.flowerType,
    );
  }
}

/// Repository errors — thrown around drift failures and bad input.
sealed class VoiceLogRepositoryError extends AppError {
  const VoiceLogRepositoryError({
    required super.message,
    super.cause,
    super.stack,
  });
}

/// Wraps a drift / sqlite exception.
final class VoiceLogStorageError extends VoiceLogRepositoryError {
  const VoiceLogStorageError({
    required super.message,
    super.cause,
    super.stack,
  });
}

/// Repository exposing the write path the record flow needs, plus a
/// reactive list stream the home screen subscribes to. Phase 1 keeps
/// the surface small; refine / embed updates arrive in later phases.
class VoiceLogRepository {
  VoiceLogRepository(this._db) : _fts = VoiceLogFts(_db);

  final VoxSynthDatabase _db;
  final VoiceLogFts _fts;

  /// Insert a freshly-recorded voice log in state [ProcessingState.recorded].
  Future<Result<VoiceLogView, VoiceLogStorageError>> insertRecorded({
    required String id,
    required DateTime createdAt,
    required int durationMs,
    required String audioPath,
    required String rawTranscript,
  }) async {
    try {
      final row = VoiceLog(
        id: id,
        createdAt: createdAt.millisecondsSinceEpoch,
        durationMs: durationMs,
        audioPath: audioPath,
        rawTranscript: rawTranscript,
        processingState: ProcessingState.recorded.wire,
        retryCount: 0,
      );
      await _db.into(_db.voiceLogs).insert(row);
      await _fts.sync(id);
      return Ok(VoiceLogView.fromRow(row));
    } on Object catch (e, s) {
      return Err(
        VoiceLogStorageError(
          message: 'Failed to insert voice log: $e',
          cause: e,
          stack: s,
        ),
      );
    }
  }

  /// Insert a voice log whose audio is captured but whose raw transcript
  /// has not yet been produced. The row appears in the home list with an
  /// empty body and state [ProcessingState.transcribing]; the worker's
  /// transcribe job will later fill `raw_transcript` and transition the
  /// row to [ProcessingState.recorded].
  Future<Result<VoiceLogView, VoiceLogStorageError>>
  insertPendingTranscription({
    required String id,
    required DateTime createdAt,
    required int durationMs,
    required String audioPath,
  }) async {
    try {
      final row = VoiceLog(
        id: id,
        createdAt: createdAt.millisecondsSinceEpoch,
        durationMs: durationMs,
        audioPath: audioPath,
        rawTranscript: '',
        processingState: ProcessingState.transcribing.wire,
        retryCount: 0,
      );
      await _db.into(_db.voiceLogs).insert(row);
      await _fts.sync(id);
      return Ok(VoiceLogView.fromRow(row));
    } on Object catch (e, s) {
      return Err(
        VoiceLogStorageError(
          message: 'Failed to insert pending log: $e',
          cause: e,
          stack: s,
        ),
      );
    }
  }

  /// Record a successful transcribe: `raw_transcript` is filled and the
  /// row transitions from [ProcessingState.transcribing] to
  /// [ProcessingState.recorded] so the refine pipeline can pick it up.
  Future<Result<void, VoiceLogStorageError>> markTranscribed({
    required String id,
    required String rawTranscript,
  }) async {
    try {
      await (_db.update(_db.voiceLogs)..where((t) => t.id.equals(id))).write(
        VoiceLogsCompanion(
          rawTranscript: Value(rawTranscript),
          processingState: Value(ProcessingState.recorded.wire),
          errorMessage: const Value(null),
        ),
      );
      await _fts.sync(id);
      return const Ok(null);
    } on Object catch (e, s) {
      return Err(
        VoiceLogStorageError(
          message: 'Failed to mark transcribed: $e',
          cause: e,
          stack: s,
        ),
      );
    }
  }

  /// Reverse-chronological stream of voice logs. Emits on every change.
  Stream<List<VoiceLogView>> watchAll() {
    final query = _db.select(_db.voiceLogs)
      ..orderBy([(t) => OrderingTerm.desc(t.createdAt)]);
    return query.watch().map((rows) => rows.map(VoiceLogView.fromRow).toList());
  }

  /// One-shot fetch for a log by id.
  Future<VoiceLogView?> find(String id) async {
    final row = await (_db.select(
      _db.voiceLogs,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    return row == null ? null : VoiceLogView.fromRow(row);
  }

  /// One-shot fetch of every log with `createdAt` in `[start, end)`,
  /// ordered oldest-first. Powers cross-log work like digests.
  Future<List<VoiceLogView>> findInWindow({
    required DateTime start,
    required DateTime end,
  }) async {
    final startMs = start.millisecondsSinceEpoch;
    final endMs = end.millisecondsSinceEpoch;
    final query = _db.select(_db.voiceLogs)
      ..where(
        (t) =>
            t.createdAt.isBiggerOrEqualValue(startMs) &
            t.createdAt.isSmallerThanValue(endMs),
      )
      ..orderBy([(t) => OrderingTerm.asc(t.createdAt)]);
    final rows = await query.get();
    return rows.map(VoiceLogView.fromRow).toList(growable: false);
  }

  /// Record a successful refine: `cleaned_text` is filled and the state
  /// transitions to [ProcessingState.refined].
  Future<Result<void, VoiceLogStorageError>> markRefined({
    required String id,
    required String cleanedText,
    String? title,
    String? flowerType,
  }) async {
    try {
      await (_db.update(_db.voiceLogs)..where((t) => t.id.equals(id))).write(
        VoiceLogsCompanion(
          cleanedText: Value(cleanedText),
          title: Value(title),
          flowerType: Value(flowerType),
          processingState: Value(ProcessingState.refined.wire),
          errorMessage: const Value(null),
        ),
      );
      await _fts.sync(id);
      return const Ok(null);
    } on Object catch (e, s) {
      return Err(
        VoiceLogStorageError(
          message: 'Failed to mark refined: $e',
          cause: e,
          stack: s,
        ),
      );
    }
  }

  /// Record a successful embed run.
  Future<Result<void, VoiceLogStorageError>> markEmbedded(String id) async {
    try {
      await (_db.update(_db.voiceLogs)..where((t) => t.id.equals(id))).write(
        VoiceLogsCompanion(
          processingState: Value(ProcessingState.embedded.wire),
          errorMessage: const Value(null),
        ),
      );
      return const Ok(null);
    } on Object catch (e, s) {
      return Err(
        VoiceLogStorageError(
          message: 'Failed to mark embedded: $e',
          cause: e,
          stack: s,
        ),
      );
    }
  }

  /// Update the user-facing title for a log. Trims whitespace; an empty
  /// trimmed value clears the title so the [VoiceLogView.displayTitle]
  /// fallback kicks back in. Re-syncs the row's FTS5 entry so search picks
  /// up the change.
  Future<Result<void, VoiceLogStorageError>> updateTitle({
    required String id,
    required String? title,
  }) async {
    try {
      final trimmed = title?.trim();
      final value = (trimmed == null || trimmed.isEmpty) ? null : trimmed;
      await (_db.update(_db.voiceLogs)..where((t) => t.id.equals(id))).write(
        VoiceLogsCompanion(title: Value(value)),
      );
      await _fts.sync(id);
      return const Ok(null);
    } on Object catch (e, s) {
      return Err(
        VoiceLogStorageError(
          message: 'Failed to update title: $e',
          cause: e,
          stack: s,
        ),
      );
    }
  }

  /// Delete a single log and its dependent rows (mentions, segments).
  /// FTS5 is cleaned up alongside.
  Future<Result<void, VoiceLogStorageError>> delete(String id) async {
    try {
      await _db.transaction(() async {
        await _fts.remove(id);
        await _removeMemorySourcesForLog(id);
        await (_db.delete(
          _db.actionItems,
        )..where((t) => t.voiceLogId.equals(id))).go();
        await (_db.delete(
          _db.entityMentions,
        )..where((t) => t.logId.equals(id))).go();
        await (_db.delete(
          _db.voiceLogSegments,
        )..where((t) => t.logId.equals(id))).go();
        await (_db.delete(
          _db.transcriptSegments,
        )..where((t) => t.logId.equals(id))).go();
        await (_db.delete(
          _db.processingJobs,
        )..where((t) => t.logId.equals(id))).go();
        await (_db.delete(_db.voiceLogs)..where((t) => t.id.equals(id))).go();
      });
      return const Ok(null);
    } on Object catch (e, s) {
      return Err(
        VoiceLogStorageError(
          message: 'Failed to delete log: $e',
          cause: e,
          stack: s,
        ),
      );
    }
  }

  /// Wipe every voice log and dependent row. Used by Settings → Delete all.
  Future<Result<void, VoiceLogStorageError>> deleteAll() async {
    try {
      await _db.transaction(() async {
        await _db.customStatement('DELETE FROM voice_logs_fts');
        await _db.customStatement('DELETE FROM memory_items_fts');
        await _db.delete(_db.askMessages).go();
        await _db.delete(_db.askThreads).go();
        await _db.delete(_db.actionItems).go();
        await _db.delete(_db.memoryEntityLinks).go();
        await _db.delete(_db.memorySources).go();
        await _db.delete(_db.memoryEmbeddings).go();
        await _db.delete(_db.memoryItems).go();
        await _db.delete(_db.entityMentions).go();
        await _db.delete(_db.voiceLogSegments).go();
        await _db.delete(_db.transcriptSegments).go();
        await _db.delete(_db.canonicalEntities).go();
        await _db.delete(_db.processingJobs).go();
        await _db.delete(_db.voiceLogs).go();
      });
      return const Ok(null);
    } on Object catch (e, s) {
      return Err(
        VoiceLogStorageError(
          message: 'Failed to delete all: $e',
          cause: e,
          stack: s,
        ),
      );
    }
  }

  Future<void> _removeMemorySourcesForLog(String logId) async {
    final rows = await _db
        .customSelect(
          'SELECT DISTINCT memory_id FROM memory_sources WHERE voice_log_id = ?',
          variables: [Variable<String>(logId)],
        )
        .get();
    final memoryIds = rows.map((r) => r.read<String>('memory_id')).toList();
    await (_db.delete(
      _db.memorySources,
    )..where((t) => t.voiceLogId.equals(logId))).go();
    for (final memoryId in memoryIds) {
      final remaining = await _db
          .customSelect(
            'SELECT COUNT(*) AS c FROM memory_sources WHERE memory_id = ?',
            variables: [Variable<String>(memoryId)],
          )
          .getSingle();
      if (remaining.read<int>('c') > 0) continue;
      final row = await _db
          .customSelect(
            'SELECT rowid FROM memory_items WHERE id = ?',
            variables: [Variable<String>(memoryId)],
          )
          .getSingleOrNull();
      if (row != null) {
        await _db.customStatement(
          'DELETE FROM memory_items_fts WHERE rowid = ?',
          [row.read<int>('rowid')],
        );
      }
      await (_db.delete(
        _db.memoryEntityLinks,
      )..where((t) => t.memoryId.equals(memoryId))).go();
      await (_db.delete(
        _db.memoryEmbeddings,
      )..where((t) => t.memoryId.equals(memoryId))).go();
      await (_db.delete(
        _db.memoryItems,
      )..where((t) => t.id.equals(memoryId))).go();
    }
  }

  /// Record a pipeline failure with a human-readable reason.
  Future<Result<void, VoiceLogStorageError>> markFailed({
    required String id,
    required String errorMessage,
  }) async {
    try {
      await (_db.update(_db.voiceLogs)..where((t) => t.id.equals(id))).write(
        VoiceLogsCompanion(
          processingState: Value(ProcessingState.failed.wire),
          errorMessage: Value(errorMessage),
        ),
      );
      return const Ok(null);
    } on Object catch (e, s) {
      return Err(
        VoiceLogStorageError(
          message: 'Failed to mark failed: $e',
          cause: e,
          stack: s,
        ),
      );
    }
  }
}
