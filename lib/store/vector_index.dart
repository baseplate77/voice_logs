import 'dart:typed_data';

import '../../objectbox.g.dart' hide Entity;
import 'objectbox_entities.dart';

/// Match returned by [VectorIndex.nearest]: the stored vector id and
/// how far (cosine distance, so lower = closer) it is from the query.
final class VectorMatch {
  const VectorMatch({
    required this.vectorId,
    required this.logId,
    required this.score,
  });

  /// Same int stored in `transcript_chunks.objectbox_id`.
  final int vectorId;

  /// The `voice_logs.id` the stored chunk came from. Denormalised so
  /// callers can cheap-delete by logId without a Drift lookup.
  final String logId;

  /// Distance score from the backend. For ObjectBox HNSW cosine this
  /// is 1 - cosine_similarity; smaller is better.
  final double score;
}

/// Pluggable vector index used by [VoiceLogRepository]. Production
/// wraps ObjectBox HNSW; tests can use [InMemoryVectorIndex] to avoid
/// loading the native objectbox dylib in the `flutter test` harness.
abstract class VectorIndex {
  /// Store a vector for a chunk and return the auto-assigned id. The
  /// repo writes the returned id into `transcript_chunks.objectbox_id`.
  int put({required String logId, required Float32List embedding});

  /// Top-`limit` nearest neighbours of [query].
  List<VectorMatch> nearest(Float32List query, int limit);

  /// Remove every vector tagged with [logId].
  void removeByLogId(String logId);

  /// Remove vectors by their ids. Used by orphan cleanup.
  void removeByIds(List<int> ids);

  /// Enumerate every (id, logId) pair cheaply — orphan cleanup reads
  /// this and cross-checks against Drift rows. Returning ids as a
  /// [List<int>] avoids loading the full vectors.
  List<int> allIds();

  /// Total vector count. Convenience for tests + metrics.
  int count();
}

/// Production implementation backed by ObjectBox HNSW (Phase 4c).
class ObjectBoxVectorIndex implements VectorIndex {
  ObjectBoxVectorIndex(this._box);

  final Box<ChunkVector> _box;

  @override
  int put({required String logId, required Float32List embedding}) => _box.put(
        ChunkVector(
          logId: logId,
          embedding: embedding.map((f) => f.toDouble()).toList(growable: false),
        ),
      );

  @override
  List<VectorMatch> nearest(Float32List query, int limit) {
    final q = _box
        .query(
          ChunkVector_.embedding.nearestNeighborsF32(query, limit),
        )
        .build();
    try {
      final results = q.findWithScores();
      return results
          .map(
            (r) => VectorMatch(
              vectorId: r.object.id,
              logId: r.object.logId,
              score: r.score,
            ),
          )
          .toList(growable: false);
    } finally {
      q.close();
    }
  }

  @override
  void removeByLogId(String logId) {
    final q = _box.query(ChunkVector_.logId.equals(logId)).build();
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

/// Pure-Dart in-memory vector index — used by tests and by any host
/// context where the objectbox native lib isn't on the library path.
/// Cosine-similarity ranked; not HNSW so O(N) per query, but for the
/// handful of rows test fixtures create that's fine.
class InMemoryVectorIndex implements VectorIndex {
  final Map<int, _Entry> _entries = <int, _Entry>{};
  int _nextId = 1;

  @override
  int put({required String logId, required Float32List embedding}) {
    final id = _nextId++;
    _entries[id] = _Entry(
      logId: logId,
      embedding: Float32List.fromList(embedding),
    );
    return id;
  }

  @override
  List<VectorMatch> nearest(Float32List query, int limit) {
    final scored = <VectorMatch>[];
    for (final entry in _entries.entries) {
      final sim = _dot(query, entry.value.embedding);
      scored.add(
        VectorMatch(
          vectorId: entry.key,
          logId: entry.value.logId,
          score: 1.0 - sim, // ObjectBox convention: lower = closer
        ),
      );
    }
    scored.sort((a, b) => a.score.compareTo(b.score));
    if (scored.length <= limit) return scored;
    return scored.sublist(0, limit);
  }

  @override
  void removeByLogId(String logId) {
    _entries.removeWhere((_, e) => e.logId == logId);
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
  const _Entry({required this.logId, required this.embedding});
  final String logId;
  final Float32List embedding;
}
