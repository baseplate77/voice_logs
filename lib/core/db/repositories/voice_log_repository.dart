import 'package:drift/drift.dart';

import '../../app_error.dart';
import '../../result.dart';
import '../database.dart';
import '../processing_state.dart';

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
    required this.processingState,
    required this.errorMessage,
  });

  final String id;
  final DateTime createdAt;
  final int durationMs;
  final String audioPath;
  final String rawTranscript;
  final String? cleanedText;
  final ProcessingState processingState;
  final String? errorMessage;

  /// The user-visible text for this log — prefers the Gemma-cleaned
  /// version and falls back to the raw transcript.
  String get displayText => cleanedText ?? rawTranscript;

  factory VoiceLogView.fromRow(VoiceLog row) {
    return VoiceLogView(
      id: row.id,
      createdAt: DateTime.fromMillisecondsSinceEpoch(row.createdAt),
      durationMs: row.durationMs,
      audioPath: row.audioPath,
      rawTranscript: row.rawTranscript,
      cleanedText: row.cleanedText,
      processingState: ProcessingState.fromWire(row.processingState),
      errorMessage: row.errorMessage,
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
  VoiceLogRepository(this._db);

  final VoxSynthDatabase _db;

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

  /// Record a successful refine: `cleaned_text` is filled and the state
  /// transitions to [ProcessingState.refined].
  Future<Result<void, VoiceLogStorageError>> markRefined({
    required String id,
    required String cleanedText,
  }) async {
    try {
      await (_db.update(_db.voiceLogs)..where((t) => t.id.equals(id))).write(
        VoiceLogsCompanion(
          cleanedText: Value(cleanedText),
          processingState: Value(ProcessingState.refined.wire),
          errorMessage: const Value(null),
        ),
      );
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
