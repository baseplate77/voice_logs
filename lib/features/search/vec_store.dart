import 'dart:typed_data';

import 'embedding_math.dart';
import 'segment_repository.dart';

/// One vector search hit.
class VectorHit {
  const VectorHit({
    required this.segmentId,
    required this.logId,
    required this.score,
    required this.text,
  });

  final String segmentId;
  final String logId;

  /// Cosine similarity, in `[-1, 1]`. Higher is more similar.
  final double score;

  final String text;
}

/// Brute-force cosine similarity index over the whole segment set.
/// Fine for ~10k segments on mid-range devices; swap for sqlite-vec
/// once we need more scale.
class VecStore {
  VecStore(this._repo);

  final SegmentRepository _repo;
  final List<StoredSegment> _segments = [];
  bool _loaded = false;

  /// Warm the store. Idempotent — calling again during a session is a
  /// no-op unless [reload] is true.
  Future<void> load({bool reload = false}) async {
    if (_loaded && !reload) return;
    _segments
      ..clear()
      ..addAll(await _repo.all());
    _loaded = true;
  }

  /// Return the top [k] hits for the given L2-normalized query vector.
  /// Results scoring below [minScore] are excluded.
  List<VectorHit> search(
    Float32List queryVec, {
    int k = 20,
    double minScore = 0.25,
  }) {
    if (_segments.isEmpty) return const [];
    final topK = <_Scored>[];
    var threshold = minScore;

    for (final seg in _segments) {
      final score = cosineSimilarity(seg.embedding, queryVec);
      if (score < threshold) continue;
      _insertSorted(topK, _Scored(seg, score));
      if (topK.length > k) {
        topK.removeLast();
        threshold = topK.last.score;
      }
    }

    return topK
        .map(
          (s) => VectorHit(
            segmentId: s.segment.id,
            logId: s.segment.logId,
            score: s.score,
            text: s.segment.text,
          ),
        )
        .toList();
  }

  static void _insertSorted(List<_Scored> list, _Scored item) {
    var lo = 0;
    var hi = list.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (list[mid].score >= item.score) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    list.insert(lo, item);
  }

  /// Update the in-memory store with newly inserted segments. Callers
  /// (typically the embed job handler) persist via [SegmentRepository]
  /// first, then notify the store.
  void replaceForLog(String logId, List<StoredSegment> fresh) {
    _segments.removeWhere((s) => s.logId == logId);
    _segments.addAll(fresh);
  }

  int get size => _segments.length;
}

class _Scored {
  const _Scored(this.segment, this.score);
  final StoredSegment segment;
  final double score;
}
