import 'package:drift/drift.dart';

import '../../../features/actions/action_types.dart';
import '../../app_error.dart';
import '../../result.dart';
import '../database.dart';

/// Repository errors for local action persistence.
sealed class ActionItemRepositoryError extends AppError {
  const ActionItemRepositoryError({
    required super.message,
    super.cause,
    super.stack,
  });
}

/// Wraps Drift/SQLite failures.
final class ActionItemStorageError extends ActionItemRepositoryError {
  const ActionItemStorageError({
    required super.message,
    super.cause,
    super.stack,
  });
}

/// Stores extracted local action items and their source evidence.
class ActionItemRepository {
  ActionItemRepository(this._db);

  final VoxSynthDatabase _db;

  /// Insert validated candidates for [voiceLogId]. Existing action items for
  /// the same log are replaced so manual/retry extraction is idempotent.
  Future<Result<List<VoiceActionItemView>, ActionItemRepositoryError>>
  replaceForLog({
    required String voiceLogId,
    required List<VoiceActionCandidate> candidates,
  }) async {
    try {
      final views = <VoiceActionItemView>[];
      await _db.transaction(() async {
        await (_db.delete(
          _db.actionItems,
        )..where((t) => t.voiceLogId.equals(voiceLogId))).go();

        final now = DateTime.now().millisecondsSinceEpoch;
        for (var i = 0; i < candidates.length; i++) {
          final candidate = candidates[i];
          final id = 'act_${DateTime.now().microsecondsSinceEpoch}_$i';
          final notificationId = _stableNotificationId(id);
          final row = ActionItem(
            id: id,
            voiceLogId: voiceLogId,
            type: candidate.type.wire,
            title: candidate.title,
            notes: candidate.notes,
            dueAt: candidate.dueAt?.millisecondsSinceEpoch,
            status: VoiceActionStatus.pending.wire,
            notificationId: candidate.dueAt == null ? null : notificationId,
            evidenceText: candidate.evidence,
            startChar: candidate.startChar,
            endChar: candidate.endChar,
            confidence: candidate.confidence.clamp(0, 1).toDouble(),
            createdAt: now,
            updatedAt: now,
          );
          await _db.into(_db.actionItems).insert(row);
          views.add(_asView(row));
        }
      });
      return Ok(views);
    } on Object catch (e, s) {
      return Err(
        ActionItemStorageError(
          message: 'Failed to store action items: $e',
          cause: e,
          stack: s,
        ),
      );
    }
  }

  /// Mark a pending action as done.
  Future<Result<void, ActionItemRepositoryError>> markDone(String id) async {
    try {
      final now = DateTime.now().millisecondsSinceEpoch;
      await (_db.update(_db.actionItems)..where((t) => t.id.equals(id))).write(
        ActionItemsCompanion(
          status: Value(VoiceActionStatus.done.wire),
          updatedAt: Value(now),
          completedAt: Value(now),
        ),
      );
      return const Ok(null);
    } on Object catch (e, s) {
      return Err(
        ActionItemStorageError(
          message: 'Failed to complete action: $e',
          cause: e,
          stack: s,
        ),
      );
    }
  }

  /// Archive an action without deleting source evidence.
  Future<Result<void, ActionItemRepositoryError>> archive(String id) async {
    try {
      await (_db.update(_db.actionItems)..where((t) => t.id.equals(id))).write(
        ActionItemsCompanion(
          status: Value(VoiceActionStatus.archived.wire),
          updatedAt: Value(DateTime.now().millisecondsSinceEpoch),
        ),
      );
      return const Ok(null);
    } on Object catch (e, s) {
      return Err(
        ActionItemStorageError(
          message: 'Failed to archive action: $e',
          cause: e,
          stack: s,
        ),
      );
    }
  }

  /// Delete a single extracted action.
  Future<Result<void, ActionItemRepositoryError>> delete(String id) async {
    try {
      await (_db.delete(_db.actionItems)..where((t) => t.id.equals(id))).go();
      return const Ok(null);
    } on Object catch (e, s) {
      return Err(
        ActionItemStorageError(
          message: 'Failed to delete action: $e',
          cause: e,
          stack: s,
        ),
      );
    }
  }

  /// Persist that a notification was successfully scheduled.
  Future<Result<void, ActionItemRepositoryError>> markNotificationScheduled({
    required String id,
    required DateTime scheduledAt,
  }) async {
    try {
      await (_db.update(_db.actionItems)..where((t) => t.id.equals(id))).write(
        ActionItemsCompanion(
          notificationScheduledAt: Value(scheduledAt.millisecondsSinceEpoch),
          updatedAt: Value(DateTime.now().millisecondsSinceEpoch),
        ),
      );
      return const Ok(null);
    } on Object catch (e, s) {
      return Err(
        ActionItemStorageError(
          message: 'Failed to mark notification scheduled: $e',
          cause: e,
          stack: s,
        ),
      );
    }
  }

  /// Fetch all actions for a source log.
  Future<List<VoiceActionItemView>> forLog(String voiceLogId) async {
    final rows = await (_db.select(
      _db.actionItems,
    )..where((t) => t.voiceLogId.equals(voiceLogId))).get();
    return rows.map(_asView).toList();
  }

  /// Watch all non-archived actions for the inbox.
  Stream<List<VoiceActionItemView>> watchInbox() {
    final query = _db.select(_db.actionItems)
      ..where((t) => t.status.equals(VoiceActionStatus.archived.wire).not())
      ..orderBy([
        (t) => OrderingTerm.asc(t.status),
        (t) => OrderingTerm.asc(t.dueAt),
        (t) => OrderingTerm.desc(t.createdAt),
      ]);
    return query.watch().map((rows) => rows.map(_asView).toList());
  }

  /// One-shot fetch for tests and notification cancellation.
  Future<VoiceActionItemView?> find(String id) async {
    final row = await (_db.select(
      _db.actionItems,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    return row == null ? null : _asView(row);
  }

  VoiceActionItemView _asView(ActionItem row) {
    return VoiceActionItemView(
      id: row.id,
      voiceLogId: row.voiceLogId,
      type: VoiceActionType.fromWireOrNull(row.type) ?? VoiceActionType.task,
      title: row.title,
      notes: row.notes,
      dueAt: row.dueAt == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(row.dueAt!),
      status: VoiceActionStatus.fromWire(row.status),
      notificationId: row.notificationId,
      notificationScheduledAt: row.notificationScheduledAt == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(row.notificationScheduledAt!),
      evidenceText: row.evidenceText,
      startChar: row.startChar,
      endChar: row.endChar,
      confidence: row.confidence,
      createdAt: DateTime.fromMillisecondsSinceEpoch(row.createdAt),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(row.updatedAt),
      completedAt: row.completedAt == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(row.completedAt!),
    );
  }

  int _stableNotificationId(String id) {
    var hash = 0;
    for (final code in id.codeUnits) {
      hash = 0x1fffffff & (hash + code);
      hash = 0x1fffffff & (hash + ((0x0007ffff & hash) << 10));
      hash ^= hash >> 6;
    }
    hash = 0x1fffffff & (hash + ((0x03ffffff & hash) << 3));
    hash ^= hash >> 11;
    hash = 0x1fffffff & (hash + ((0x00003fff & hash) << 15));
    return hash == 0 ? 1 : hash;
  }
}
