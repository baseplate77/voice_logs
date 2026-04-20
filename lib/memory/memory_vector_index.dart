import 'dart:typed_data';

import '../../objectbox.g.dart' hide Entity;
import '../store/objectbox_entities.dart';

/// Match returned by [MemoryVectorIndex.nearest]: the stored vector's
/// ObjectBox id, the owning memory id, and the cosine distance.
final class MemoryVectorMatch {
  const MemoryVectorMatch({
    required this.vectorId,
    required this.memoryId,
    required this.score,
  });

  /// Stored `memories.objectbox_id`.
  final int vectorId;

  /// The `memories.id` (TEXT / UUID).
  final String memoryId;

  /// Distance score from the backend (ObjectBox HNSW cosine: lower = closer).
  final double score;
}

/// Pluggable index for memory embeddings. Production wraps ObjectBox
/// HNSW; tests use [InMemoryMemoryVectorIndex] to avoid loading the
/// native objectbox dylib under `flutter test`.
abstract class MemoryVectorIndex {
  /// Store a vector for a memory and return the auto-assigned id. The
  /// repo writes this id into `memories.objectbox_id`.
  int put({required String memoryId, required Float32List embedding});

  /// Top-`limit` nearest neighbours of [query].
  List<MemoryVectorMatch> nearest(Float32List query, int limit);

  /// Remove every vector tagged with [memoryId].
  void removeByMemoryId(String memoryId);

  /// Remove vectors by ObjectBox ids. Used by orphan cleanup.
  void removeByIds(List<int> ids);

  /// Enumerate every (id, memoryId) pair cheaply — orphan cleanup
  /// reads this and cross-checks against Drift.
  List<int> allIds();

  /// Total vector count. Convenience for tests + metrics.
  int count();
}

/// Production implementation backed by ObjectBox HNSW.
class ObjectBoxMemoryVectorIndex implements MemoryVectorIndex {
  ObjectBoxMemoryVectorIndex(this._box);

  final Box<MemoryVector> _box;

  @override
  int put({required String memoryId, required Float32List embedding}) =>
      _box.put(
        MemoryVector(
          memoryId: memoryId,
          embedding:
              embedding.map((f) => f.toDouble()).toList(growable: false),
        ),
      );

  @override
  List<MemoryVectorMatch> nearest(Float32List query, int limit) {
    final q = _box
        .query(
          MemoryVector_.embedding.nearestNeighborsF32(query, limit),
        )
        .build();
    try {
      final results = q.findWithScores();
      return results
          .map(
            (r) => MemoryVectorMatch(
              vectorId: r.object.id,
              memoryId: r.object.memoryId,
              score: r.score,
            ),
          )
          .toList(growable: false);
    } finally {
      q.close();
    }
  }

  @override
  void removeByMemoryId(String memoryId) {
    final q = _box.query(MemoryVector_.memoryId.equals(memoryId)).build();
    try {
      q.remove();
    } finally {
      q.close();
    }
  }

  @override
  void removeByIds(List<int> ids) {
    if (ids.isEmpty) return;
    _box.removeMany(ids);
  }

  @override
  List<int> allIds() =>
      _box.getAll().map((v) => v.id).toList(growable: false);

  @override
  int count() => _box.count();
}

/// Pure-Dart in-memory index for tests. Cosine-similarity ranked; O(N)
/// per query, which is fine for the handful of rows fixtures create.
class InMemoryMemoryVectorIndex implements MemoryVectorIndex {
  final Map<int, _Entry> _entries = <int, _Entry>{};
  int _nextId = 1;

  @override
  int put({required String memoryId, required Float32List embedding}) {
    final id = _nextId++;
    _entries[id] = _Entry(
      memoryId: memoryId,
      embedding: Float32List.fromList(embedding),
    );
    return id;
  }

  @override
  List<MemoryVectorMatch> nearest(Float32List query, int limit) {
    final scored = <MemoryVectorMatch>[];
    for (final entry in _entries.entries) {
      final sim = _dot(query, entry.value.embedding);
      scored.add(
        MemoryVectorMatch(
          vectorId: entry.key,
          memoryId: entry.value.memoryId,
          score: 1.0 - sim, // lower = closer per ObjectBox convention
        ),
      );
    }
    scored.sort((a, b) => a.score.compareTo(b.score));
    if (scored.length <= limit) return scored;
    return scored.sublist(0, limit);
  }

  @override
  void removeByMemoryId(String memoryId) {
    _entries.removeWhere((_, e) => e.memoryId == memoryId);
  }

  @override
  void removeByIds(List<int> ids) {
    for (final id in ids) {
      _entries.remove(id);
    }
  }

  @override
  List<int> allIds() => _entries.keys.toList(growable: false);

  @override
  int count() => _entries.length;

  static double _dot(Float32List a, Float32List b) {
    assert(a.length == b.length);
    var s = 0.0;
    for (var i = 0; i < a.length; i++) {
      s += a[i] * b[i];
    }
    return s;
  }
}

class _Entry {
  const _Entry({required this.memoryId, required this.embedding});
  final String memoryId;
  final Float32List embedding;
}
