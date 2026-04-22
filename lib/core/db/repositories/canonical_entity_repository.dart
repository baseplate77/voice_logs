import 'dart:typed_data';

import 'package:drift/drift.dart';

import '../../app_error.dart';
import '../../result.dart';
import '../database.dart';

/// Data-transfer view of a canonical entity.
class CanonicalEntityView {
  const CanonicalEntityView({
    required this.id,
    required this.displayName,
    required this.type,
    required this.mentionCount,
    required this.createdAt,
    required this.embedding,
  });

  final String id;
  final String displayName;
  final String type;
  final int mentionCount;
  final DateTime createdAt;

  /// L2-normalized Float32 vector stored alongside the canonical row so
  /// future mentions can match against it without re-embedding.
  final Float32List embedding;
}

sealed class CanonicalEntityError extends AppError {
  const CanonicalEntityError({
    required super.message,
    super.cause,
    super.stack,
  });
}

final class CanonicalEntityDbError extends CanonicalEntityError {
  const CanonicalEntityDbError({
    required super.message,
    super.cause,
    super.stack,
  });
}

/// Stores canonical entities alongside their e5 embeddings. The drift
/// schema keeps the embedding blob in `canonical_entities.embedding`
/// (added in schema v3 below). Keeps both id-lookup and a reactive
/// ordered stream for the UI.
class CanonicalEntityRepository {
  CanonicalEntityRepository(this._db);

  final VoxSynthDatabase _db;

  /// All canonical entities of a given type ordered by id. Caller is
  /// expected to compute similarity in Dart — there's no efficient
  /// server-side vector search until sqlite-vec lands.
  Future<List<CanonicalEntityView>> byType(String type) async {
    final rows = await (_db.select(
      _db.canonicalEntities,
    )..where((t) => t.type.equals(type))).get();
    return rows.map(_asView).toList();
  }

  /// Reverse-sorted by mention frequency for the Entities list screen.
  Stream<List<CanonicalEntityView>> watchAll() {
    final query = _db.select(_db.canonicalEntities)
      ..orderBy([
        (t) => OrderingTerm.desc(t.mentionCount),
        (t) => OrderingTerm.desc(t.createdAt),
      ]);
    return query.watch().map((rows) => rows.map(_asView).toList());
  }

  /// Create a new canonical entity. The initial embedding is the
  /// embedding of the first mention (surface text + context); it
  /// anchors future similarity matches for this entity.
  Future<Result<String, CanonicalEntityError>> create({
    required String displayName,
    required String type,
    required Float32List embedding,
  }) async {
    final id = 'ce_${DateTime.now().microsecondsSinceEpoch}';
    try {
      await _db
          .into(_db.canonicalEntities)
          .insert(
            CanonicalEntity(
              id: id,
              displayName: displayName,
              type: type,
              mentionCount: 1,
              createdAt: DateTime.now().millisecondsSinceEpoch,
              embedding: _floatsToBytes(embedding),
            ),
          );
      return Ok(id);
    } on Object catch (e, s) {
      return Err(
        CanonicalEntityDbError(
          message: 'Failed to create canonical entity: $e',
          cause: e,
          stack: s,
        ),
      );
    }
  }

  /// Bump [mentionCount] by one on an existing canonical entity.
  Future<void> incrementMentionCount(String id) async {
    await _db.customStatement(
      'UPDATE canonical_entities SET mention_count = mention_count + 1 '
      'WHERE id = ?',
      [id],
    );
  }

  CanonicalEntityView _asView(CanonicalEntity row) => CanonicalEntityView(
    id: row.id,
    displayName: row.displayName,
    type: row.type,
    mentionCount: row.mentionCount,
    createdAt: DateTime.fromMillisecondsSinceEpoch(row.createdAt),
    embedding: _bytesToFloats(row.embedding),
  );

  static Uint8List _floatsToBytes(Float32List floats) =>
      floats.buffer.asUint8List(floats.offsetInBytes, floats.lengthInBytes);

  static Float32List _bytesToFloats(Uint8List bytes) =>
      Uint8List.fromList(bytes).buffer.asFloat32List();
}
