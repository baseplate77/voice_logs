import 'dart:typed_data';

import 'package:drift/drift.dart';

import '../../../features/memory/memory_types.dart';
import '../../../features/search/embedding_math.dart';
import '../../app_error.dart';
import '../../result.dart';
import '../database.dart';

/// Confidence required for a normal memory to become active immediately.
const double kMemoryAutoActivateConfidence = 0.85;

/// Cosine threshold for treating a new candidate as evidence for an existing
/// memory instead of creating a duplicate.
const double kMemoryDedupeSimilarity = 0.9;

/// Repository errors for local memory persistence.
sealed class MemoryRepositoryError extends AppError {
  const MemoryRepositoryError({
    required super.message,
    super.cause,
    super.stack,
  });
}

/// Wraps Drift/SQLite failures.
final class MemoryStorageError extends MemoryRepositoryError {
  const MemoryStorageError({required super.message, super.cause, super.stack});
}

/// Stores local-only memory cards, their evidence, entity links, and e5
/// embeddings. The repository also owns FTS synchronization for memory cards.
class MemoryRepository {
  MemoryRepository(
    this._db, {
    double autoActivateConfidence = kMemoryAutoActivateConfidence,
    double dedupeSimilarity = kMemoryDedupeSimilarity,
  }) : _autoActivateConfidence = autoActivateConfidence,
       _dedupeSimilarity = dedupeSimilarity;

  final VoxSynthDatabase _db;
  final double _autoActivateConfidence;
  final double _dedupeSimilarity;

  /// Insert a new memory or update the best existing duplicate.
  Future<Result<MemoryItemView, MemoryRepositoryError>> createOrUpdate({
    required MemoryCandidate candidate,
    required String sourceLogId,
    required Float32List embedding,
    List<String> canonicalEntityIds = const [],
  }) async {
    try {
      late MemoryItemView view;
      await _db.transaction(() async {
        final now = DateTime.now().millisecondsSinceEpoch;
        final normalized = normalizeMemoryText(candidate.text);
        final duplicate = await _findDuplicate(
          normalizedText: normalized,
          embedding: embedding,
        );

        if (duplicate == null) {
          final id = 'mem_${DateTime.now().microsecondsSinceEpoch}';
          final status = _initialStatus(candidate);
          await _db
              .into(_db.memoryItems)
              .insert(
                MemoryItem(
                  id: id,
                  type: candidate.type.wire,
                  memoryText: candidate.text,
                  normalizedText: normalized,
                  confidence: candidate.confidence.clamp(0, 1).toDouble(),
                  status: status.wire,
                  sensitivity: candidate.sensitivity.wire,
                  firstSeenAt: now,
                  lastSeenAt: now,
                  createdAt: now,
                  updatedAt: now,
                ),
              );
          await _upsertEmbedding(id, embedding);
          await _insertSource(id, sourceLogId, candidate);
          await _replaceLinks(id, canonicalEntityIds);
          await _syncFts(id);
          view = (await _findRequired(id))!;
          return;
        }

        final sourceCount = await _sourceCount(duplicate.id);
        final confidence = _mergedConfidence(
          duplicate.confidence,
          candidate.confidence,
          sourceCount + 1,
        );
        final status = _mergedStatus(
          existing: duplicate.status,
          sensitivity: duplicate.sensitivity,
          confidence: confidence,
          sourceCountAfterInsert: sourceCount + 1,
        );
        await (_db.update(
          _db.memoryItems,
        )..where((t) => t.id.equals(duplicate.id))).write(
          MemoryItemsCompanion(
            confidence: Value(confidence),
            status: Value(status.wire),
            lastSeenAt: Value(now),
            updatedAt: Value(now),
          ),
        );
        await _upsertEmbedding(duplicate.id, embedding);
        await _insertSource(duplicate.id, sourceLogId, candidate);
        await _addLinks(duplicate.id, canonicalEntityIds);
        await _syncFts(duplicate.id);
        view = (await _findRequired(duplicate.id))!;
      });
      return Ok(view);
    } on Object catch (e, s) {
      return Err(
        MemoryStorageError(
          message: 'Failed to create or update memory: $e',
          cause: e,
          stack: s,
        ),
      );
    }
  }

  /// Fetch a memory by id, excluding deleted rows by default.
  Future<MemoryItemView?> find(String id, {bool includeDeleted = false}) async {
    final row =
        await (_db.select(_db.memoryItems)..where((t) {
              final idExpr = t.id.equals(id);
              return includeDeleted
                  ? idExpr
                  : idExpr &
                        t.status
                            .equalsExp(Variable(MemoryStatus.deleted.wire))
                            .not();
            }))
            .getSingleOrNull();
    if (row == null) return null;
    return _asView(row, await _embeddingFor(row.id));
  }

  /// All non-deleted memories, ordered for the Memory screen.
  Future<List<MemoryItemView>> all({bool includeArchived = true}) async {
    final query = _db.select(_db.memoryItems)
      ..where((t) {
        final notDeleted = t.status.equals(MemoryStatus.deleted.wire).not();
        if (includeArchived) return notDeleted;
        return notDeleted & t.status.equals(MemoryStatus.archived.wire).not();
      })
      ..orderBy([
        (t) => OrderingTerm.desc(t.updatedAt),
        (t) => OrderingTerm.desc(t.confidence),
      ]);
    final rows = await query.get();
    final out = <MemoryItemView>[];
    for (final row in rows) {
      out.add(_asView(row, await _embeddingFor(row.id)));
    }
    return out;
  }

  /// Active memories with embeddings, for local vector retrieval.
  Future<List<MemoryItemView>> activeWithEmbeddings() async {
    final rows = await (_db.select(
      _db.memoryItems,
    )..where((t) => t.status.equals(MemoryStatus.active.wire))).get();
    final out = <MemoryItemView>[];
    for (final row in rows) {
      final embedding = await _embeddingFor(row.id);
      if (embedding != null) out.add(_asView(row, embedding));
    }
    return out;
  }

  /// Reactive stream for future Memory UI.
  Stream<List<MemoryItemView>> watchAll() async* {
    final query = _db.select(_db.memoryItems)
      ..where((t) => t.status.equals(MemoryStatus.deleted.wire).not())
      ..orderBy([(t) => OrderingTerm.desc(t.updatedAt)]);
    await for (final rows in query.watch()) {
      final out = <MemoryItemView>[];
      for (final row in rows) {
        out.add(_asView(row, await _embeddingFor(row.id)));
      }
      yield out;
    }
  }

  /// Mark a candidate as active so it can be used in prompts and retrieval.
  Future<Result<void, MemoryRepositoryError>> confirm(String id) async {
    try {
      await (_db.update(_db.memoryItems)..where((t) => t.id.equals(id))).write(
        MemoryItemsCompanion(
          status: Value(MemoryStatus.active.wire),
          updatedAt: Value(DateTime.now().millisecondsSinceEpoch),
        ),
      );
      await _syncFts(id);
      return const Ok(null);
    } on Object catch (e, s) {
      return Err(
        MemoryStorageError(
          message: 'Failed to confirm memory: $e',
          cause: e,
          stack: s,
        ),
      );
    }
  }

  /// Archive a memory without deleting its evidence.
  Future<Result<void, MemoryRepositoryError>> archive(String id) async {
    try {
      await (_db.update(_db.memoryItems)..where((t) => t.id.equals(id))).write(
        MemoryItemsCompanion(
          status: Value(MemoryStatus.archived.wire),
          updatedAt: Value(DateTime.now().millisecondsSinceEpoch),
        ),
      );
      await _removeFts(id);
      return const Ok(null);
    } on Object catch (e, s) {
      return Err(
        MemoryStorageError(
          message: 'Failed to archive memory: $e',
          cause: e,
          stack: s,
        ),
      );
    }
  }

  /// Delete one memory card and all derived memory-only rows. Source voice logs
  /// are intentionally preserved.
  Future<Result<void, MemoryRepositoryError>> delete(String id) async {
    try {
      await _db.transaction(() async {
        await _removeFts(id);
        await (_db.delete(
          _db.memoryEntityLinks,
        )..where((t) => t.memoryId.equals(id))).go();
        await (_db.delete(
          _db.memorySources,
        )..where((t) => t.memoryId.equals(id))).go();
        await (_db.delete(
          _db.memoryEmbeddings,
        )..where((t) => t.memoryId.equals(id))).go();
        await (_db.delete(_db.memoryItems)..where((t) => t.id.equals(id))).go();
      });
      return const Ok(null);
    } on Object catch (e, s) {
      return Err(
        MemoryStorageError(
          message: 'Failed to delete memory: $e',
          cause: e,
          stack: s,
        ),
      );
    }
  }

  /// Merge [sourceId] into [targetId], moving evidence and entity links before
  /// deleting the source memory card.
  Future<Result<void, MemoryRepositoryError>> merge({
    required String sourceId,
    required String targetId,
  }) async {
    if (sourceId == targetId) return const Ok(null);
    try {
      await _db.transaction(() async {
        final source = await _findRequired(sourceId);
        final target = await _findRequired(targetId);
        if (source == null || target == null) return;

        await _db.customStatement(
          'UPDATE memory_sources SET memory_id = ? WHERE memory_id = ?',
          [targetId, sourceId],
        );
        final links = await (_db.select(
          _db.memoryEntityLinks,
        )..where((t) => t.memoryId.equals(sourceId))).get();
        for (final link in links) {
          await _db
              .into(_db.memoryEntityLinks)
              .insert(
                MemoryEntityLink(
                  memoryId: targetId,
                  canonicalEntityId: link.canonicalEntityId,
                ),
                mode: InsertMode.insertOrIgnore,
              );
        }
        await (_db.delete(
          _db.memoryEntityLinks,
        )..where((t) => t.memoryId.equals(sourceId))).go();
        await (_db.delete(
          _db.memoryEmbeddings,
        )..where((t) => t.memoryId.equals(sourceId))).go();
        await _removeFts(sourceId);
        await (_db.delete(
          _db.memoryItems,
        )..where((t) => t.id.equals(sourceId))).go();

        final confidence = _mergedConfidence(
          target.confidence,
          source.confidence,
          await _sourceCount(targetId),
        );
        await (_db.update(
          _db.memoryItems,
        )..where((t) => t.id.equals(targetId))).write(
          MemoryItemsCompanion(
            confidence: Value(confidence),
            lastSeenAt: Value(
              target.lastSeenAt.isAfter(source.lastSeenAt)
                  ? target.lastSeenAt.millisecondsSinceEpoch
                  : source.lastSeenAt.millisecondsSinceEpoch,
            ),
            updatedAt: Value(DateTime.now().millisecondsSinceEpoch),
          ),
        );
        await _syncFts(targetId);
      });
      return const Ok(null);
    } on Object catch (e, s) {
      return Err(
        MemoryStorageError(
          message: 'Failed to merge memories: $e',
          cause: e,
          stack: s,
        ),
      );
    }
  }

  MemoryStatus _initialStatus(MemoryCandidate candidate) {
    if (candidate.sensitivity == MemorySensitivity.sensitive) {
      return MemoryStatus.candidate;
    }
    return candidate.confidence >= _autoActivateConfidence
        ? MemoryStatus.active
        : MemoryStatus.candidate;
  }

  MemoryStatus _mergedStatus({
    required MemoryStatus existing,
    required MemorySensitivity sensitivity,
    required double confidence,
    required int sourceCountAfterInsert,
  }) {
    if (existing == MemoryStatus.deleted || existing == MemoryStatus.archived) {
      return existing;
    }
    if (sensitivity == MemorySensitivity.sensitive) {
      return existing == MemoryStatus.active
          ? MemoryStatus.active
          : MemoryStatus.candidate;
    }
    if (existing == MemoryStatus.active ||
        confidence >= _autoActivateConfidence ||
        sourceCountAfterInsert >= 2) {
      return MemoryStatus.active;
    }
    return MemoryStatus.candidate;
  }

  double _mergedConfidence(double current, double incoming, int sourceCount) {
    final boosted = incoming + (sourceCount - 1) * 0.03;
    final value = current > boosted ? current : boosted;
    return value.clamp(0, 1).toDouble();
  }

  Future<MemoryItemView?> _findDuplicate({
    required String normalizedText,
    required Float32List embedding,
  }) async {
    final rows =
        await (_db.select(_db.memoryItems)..where(
              (t) =>
                  t.status.equals(MemoryStatus.deleted.wire).not() &
                  t.status.equals(MemoryStatus.archived.wire).not(),
            ))
            .get();
    MemoryItemView? best;
    var bestScore = _dedupeSimilarity;
    for (final row in rows) {
      final view = _asView(row, await _embeddingFor(row.id));
      if (view.normalizedText == normalizedText) return view;
      final existingEmbedding = view.embedding;
      if (existingEmbedding == null ||
          existingEmbedding.length != embedding.length) {
        continue;
      }
      final score = cosineSimilarity(existingEmbedding, embedding);
      if (score >= bestScore) {
        bestScore = score;
        best = view;
      }
    }
    return best;
  }

  Future<void> _insertSource(
    String memoryId,
    String sourceLogId,
    MemoryCandidate candidate,
  ) async {
    await _db
        .into(_db.memorySources)
        .insert(
          MemorySource(
            id: '${memoryId}_src_${DateTime.now().microsecondsSinceEpoch}',
            memoryId: memoryId,
            voiceLogId: sourceLogId,
            startChar: candidate.startChar,
            endChar: candidate.endChar,
            evidenceText: candidate.evidence,
          ),
        );
  }

  Future<void> _replaceLinks(String memoryId, List<String> entityIds) async {
    await (_db.delete(
      _db.memoryEntityLinks,
    )..where((t) => t.memoryId.equals(memoryId))).go();
    await _addLinks(memoryId, entityIds);
  }

  Future<void> _addLinks(String memoryId, List<String> entityIds) async {
    for (final entityId in entityIds.toSet()) {
      await _db
          .into(_db.memoryEntityLinks)
          .insert(
            MemoryEntityLink(memoryId: memoryId, canonicalEntityId: entityId),
            mode: InsertMode.insertOrIgnore,
          );
    }
  }

  Future<void> _upsertEmbedding(String memoryId, Float32List embedding) async {
    await _db
        .into(_db.memoryEmbeddings)
        .insert(
          MemoryEmbedding(
            memoryId: memoryId,
            dim: embedding.length,
            embedding: _floatsToBytes(embedding),
          ),
          mode: InsertMode.insertOrReplace,
        );
  }

  Future<int> _sourceCount(String memoryId) async {
    final row = await _db
        .customSelect(
          'SELECT COUNT(*) AS c FROM memory_sources WHERE memory_id = ?',
          variables: [Variable<String>(memoryId)],
        )
        .getSingle();
    return row.read<int>('c');
  }

  Future<MemoryItemView?> _findRequired(String id) =>
      find(id, includeDeleted: true);

  Future<Float32List?> _embeddingFor(String memoryId) async {
    final row = await (_db.select(
      _db.memoryEmbeddings,
    )..where((t) => t.memoryId.equals(memoryId))).getSingleOrNull();
    if (row == null) return null;
    return _bytesToFloats(row.embedding);
  }

  Future<void> _syncFts(String memoryId) async {
    final row = await _db
        .customSelect(
          'SELECT rowid, text, normalized_text FROM memory_items WHERE id = ?',
          variables: [Variable<String>(memoryId)],
        )
        .getSingleOrNull();
    if (row == null) return;
    final rowId = row.read<int>('rowid');
    await _db.customStatement('DELETE FROM memory_items_fts WHERE rowid = ?', [
      rowId,
    ]);
    final status = await (_db.select(
      _db.memoryItems,
    )..where((t) => t.id.equals(memoryId))).getSingle();
    if (status.status != MemoryStatus.active.wire) return;
    await _db.customStatement(
      'INSERT INTO memory_items_fts(rowid, text, normalized_text) VALUES (?, ?, ?)',
      [rowId, row.read<String>('text'), row.read<String>('normalized_text')],
    );
  }

  Future<void> _removeFts(String memoryId) async {
    final row = await _db
        .customSelect(
          'SELECT rowid FROM memory_items WHERE id = ?',
          variables: [Variable<String>(memoryId)],
        )
        .getSingleOrNull();
    if (row == null) return;
    await _db.customStatement('DELETE FROM memory_items_fts WHERE rowid = ?', [
      row.read<int>('rowid'),
    ]);
  }

  MemoryItemView _asView(MemoryItem row, Float32List? embedding) {
    return MemoryItemView(
      id: row.id,
      type: MemoryType.fromWireOrNull(row.type) ?? MemoryType.eventContext,
      text: row.memoryText,
      normalizedText: row.normalizedText,
      confidence: row.confidence,
      status: MemoryStatus.fromWire(row.status),
      sensitivity:
          MemorySensitivity.fromWireOrNull(row.sensitivity) ??
          MemorySensitivity.normal,
      firstSeenAt: DateTime.fromMillisecondsSinceEpoch(row.firstSeenAt),
      lastSeenAt: DateTime.fromMillisecondsSinceEpoch(row.lastSeenAt),
      createdAt: DateTime.fromMillisecondsSinceEpoch(row.createdAt),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(row.updatedAt),
      embedding: embedding,
    );
  }

  static Uint8List _floatsToBytes(Float32List floats) =>
      floats.buffer.asUint8List(floats.offsetInBytes, floats.lengthInBytes);

  static Float32List _bytesToFloats(Uint8List bytes) =>
      Uint8List.fromList(bytes).buffer.asFloat32List();
}

/// Normalize a memory sentence for deduplication and FTS.
String normalizeMemoryText(String text) => text
    .toLowerCase()
    .replaceAll(RegExp(r'\s+'), ' ')
    .replaceAll(RegExp(r'[^a-z0-9 ]'), '')
    .trim();
