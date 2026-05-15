import '../../../features/refine/entity_summary_prompt.dart';
import '../../app_error.dart';
import '../../result.dart';
import '../database.dart';

/// View of an entity's Gemma-generated relationship / context summary.
class EntitySummaryView {
  const EntitySummaryView({
    required this.entityId,
    required this.summaryText,
    required this.structuredFacts,
    required this.mentionCountAtGeneration,
    required this.modelVersion,
    required this.generatedAt,
  });

  final String entityId;
  final String summaryText;

  /// Decoded structured facts. Null when the row predates the structured
  /// facts column (legacy) or when the JSON failed to decode.
  final EntityStructuredFacts? structuredFacts;
  final int mentionCountAtGeneration;
  final String modelVersion;
  final DateTime generatedAt;

  factory EntitySummaryView.fromRow(EntitySummary row) {
    return EntitySummaryView(
      entityId: row.entityId,
      summaryText: row.summaryText,
      structuredFacts: EntityStructuredFacts.decode(row.structuredFacts),
      mentionCountAtGeneration: row.mentionCountAtGeneration,
      modelVersion: row.modelVersion,
      generatedAt: DateTime.fromMillisecondsSinceEpoch(row.generatedAt),
    );
  }
}

sealed class EntitySummaryError extends AppError {
  const EntitySummaryError({required super.message, super.cause, super.stack});
}

final class EntitySummaryStorageError extends EntitySummaryError {
  const EntitySummaryStorageError({
    required super.message,
    super.cause,
    super.stack,
  });
}

/// Persists the per-entity summary surfaced on the entity detail page.
/// One row per canonical entity; [upsert] replaces in place so callers
/// don't have to branch on existence.
class EntitySummaryRepository {
  EntitySummaryRepository(this._db);

  final VoxSynthDatabase _db;

  Future<Result<EntitySummaryView, EntitySummaryError>> upsert({
    required String entityId,
    required String summaryText,
    required int mentionCount,
    required String modelVersion,
    EntityStructuredFacts? structuredFacts,
  }) async {
    try {
      final now = DateTime.now().millisecondsSinceEpoch;
      final row = EntitySummary(
        entityId: entityId,
        summaryText: summaryText,
        structuredFacts: EntityStructuredFacts.encode(structuredFacts),
        mentionCountAtGeneration: mentionCount,
        modelVersion: modelVersion,
        generatedAt: now,
      );
      await _db.into(_db.entitySummaries).insertOnConflictUpdate(row);
      return Ok(EntitySummaryView.fromRow(row));
    } on Object catch (e, s) {
      return Err(
        EntitySummaryStorageError(
          message: 'Failed to upsert entity summary: $e',
          cause: e,
          stack: s,
        ),
      );
    }
  }

  Future<EntitySummaryView?> find(String entityId) async {
    final row = await (_db.select(
      _db.entitySummaries,
    )..where((t) => t.entityId.equals(entityId))).getSingleOrNull();
    return row == null ? null : EntitySummaryView.fromRow(row);
  }

  /// Reactive stream of the summary for a single entity. Emits null when
  /// no row exists yet so the UI can render a skeleton.
  Stream<EntitySummaryView?> watchForEntity(String entityId) {
    final query = _db.select(_db.entitySummaries)
      ..where((t) => t.entityId.equals(entityId));
    return query.watch().map(
      (rows) => rows.isEmpty ? null : EntitySummaryView.fromRow(rows.first),
    );
  }

  /// True when the stored summary is missing or its mention-count snapshot
  /// is at least [growthThreshold] behind [currentMentionCount]. Used by
  /// the entity_summary job to decide whether a fresh Gemma call is worth
  /// making.
  Future<bool> needsRegeneration({
    required String entityId,
    required int currentMentionCount,
    int growthThreshold = 1,
  }) async {
    final existing = await find(entityId);
    if (existing == null) return true;
    return currentMentionCount - existing.mentionCountAtGeneration >=
        growthThreshold;
  }

  Future<void> delete(String entityId) async {
    await (_db.delete(
      _db.entitySummaries,
    )..where((t) => t.entityId.equals(entityId))).go();
  }
}
