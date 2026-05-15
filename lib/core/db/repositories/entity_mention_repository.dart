import 'package:drift/drift.dart';

import '../../../features/refine/offset_recovery.dart';
import '../../app_error.dart';
import '../../result.dart';
import '../database.dart';

/// Data transfer shape for UI — avoids leaking drift types.
class EntityMentionView {
  const EntityMentionView({
    required this.id,
    required this.logId,
    required this.text,
    required this.type,
    required this.charStart,
    required this.charEnd,
    required this.canonicalEntityId,
  });

  final String id;
  final String logId;
  final String text;
  final String type;
  final int charStart;
  final int charEnd;
  final String? canonicalEntityId;

  factory EntityMentionView.fromRow(EntityMention row) => EntityMentionView(
    id: row.id,
    logId: row.logId,
    text: row.mentionText,
    type: row.type,
    charStart: row.charStart,
    charEnd: row.charEnd,
    canonicalEntityId: row.canonicalEntityId,
  );
}

sealed class EntityMentionError extends AppError {
  const EntityMentionError({required super.message, super.cause, super.stack});
}

final class EntityMentionDbError extends EntityMentionError {
  const EntityMentionDbError({
    required super.message,
    super.cause,
    super.stack,
  });
}

/// Repository for the entity-mention table. Canonicalization (wiring
/// `canonical_entity_id`) arrives in Phase 5.
class EntityMentionRepository {
  EntityMentionRepository(this._db);

  final VoxSynthDatabase _db;

  /// Replace all mentions for [logId] with [mentions]. Transactional —
  /// the old set is cleared before the new rows are written.
  Future<Result<void, EntityMentionError>> replaceForLog({
    required String logId,
    required List<LocatedMention> mentions,
  }) async {
    try {
      await _db.transaction(() async {
        await (_db.delete(
          _db.entityMentions,
        )..where((t) => t.logId.equals(logId))).go();
        for (var i = 0; i < mentions.length; i++) {
          final m = mentions[i];
          await _db
              .into(_db.entityMentions)
              .insert(
                EntityMention(
                  id: '${logId}_m$i',
                  logId: logId,
                  mentionText: m.text,
                  type: m.type,
                  charStart: m.charStart,
                  charEnd: m.charEnd,
                ),
              );
        }
      });
      return const Ok(null);
    } on Object catch (e, s) {
      return Err(
        EntityMentionDbError(
          message: 'Failed to replace mentions: $e',
          cause: e,
          stack: s,
        ),
      );
    }
  }

  /// Fetch all mentions for a log, ordered by character position.
  Future<List<EntityMentionView>> forLog(String logId) async {
    final query = _db.select(_db.entityMentions)
      ..where((t) => t.logId.equals(logId))
      ..orderBy([(t) => OrderingTerm.asc(t.charStart)]);
    final rows = await query.get();
    return rows.map(EntityMentionView.fromRow).toList();
  }

  /// Reactive stream for the detail screen.
  Stream<List<EntityMentionView>> watchForLog(String logId) {
    final query = _db.select(_db.entityMentions)
      ..where((t) => t.logId.equals(logId))
      ..orderBy([(t) => OrderingTerm.asc(t.charStart)]);
    return query.watch().map(
      (rows) => rows.map(EntityMentionView.fromRow).toList(),
    );
  }

  /// Distinct voice-log ids that have at least one mention linked to
  /// [canonicalEntityId]. Ordered by most-recent log first. Powers the
  /// entity detail page's "Conversations / Timeline" section.
  Future<List<String>> logIdsForEntity(
    String canonicalEntityId, {
    int limit = 50,
  }) async {
    final rows = await _db
        .customSelect(
          'SELECT DISTINCT em.log_id AS log_id, vl.created_at AS created_at '
          'FROM entity_mentions em '
          'INNER JOIN voice_logs vl ON vl.id = em.log_id '
          'WHERE em.canonical_entity_id = ? '
          'ORDER BY vl.created_at DESC '
          'LIMIT ?',
          variables: [
            Variable<String>(canonicalEntityId),
            Variable<int>(limit),
          ],
          readsFrom: {_db.entityMentions, _db.voiceLogs},
        )
        .get();
    return rows.map((r) => r.read<String>('log_id')).toList(growable: false);
  }

  /// Reactive variant of [logIdsForEntity]. Emits whenever a relevant log
  /// is added, refined, or a mention is relinked — useful for the live
  /// "Conversations" list on the entity detail page.
  Stream<List<String>> watchLogIdsForEntity(
    String canonicalEntityId, {
    int limit = 50,
  }) {
    return _db
        .customSelect(
          'SELECT DISTINCT em.log_id AS log_id, vl.created_at AS created_at '
          'FROM entity_mentions em '
          'INNER JOIN voice_logs vl ON vl.id = em.log_id '
          'WHERE em.canonical_entity_id = ? '
          'ORDER BY vl.created_at DESC '
          'LIMIT ?',
          variables: [
            Variable<String>(canonicalEntityId),
            Variable<int>(limit),
          ],
          readsFrom: {_db.entityMentions, _db.voiceLogs},
        )
        .watch()
        .map(
          (rows) =>
              rows.map((r) => r.read<String>('log_id')).toList(growable: false),
        );
  }
}
