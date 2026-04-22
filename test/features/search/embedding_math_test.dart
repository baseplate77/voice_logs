import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:voxsynth/features/search/embedding_math.dart';

void main() {
  test('meanPool averages only unmasked positions', () {
    // batch=1, seq=3, hidden=2, pattern: [[1,2],[3,4],[5,6]]
    // mask: [1,1,0] — third token is PAD; expected mean = [(1+3)/2,(2+4)/2]
    final hidden = Float32List.fromList([1, 2, 3, 4, 5, 6]);
    final mask = Float32List.fromList([1, 1, 0]);
    final pooled = meanPool(
      lastHiddenState: hidden,
      attentionMask: mask,
      batch: 1,
      seq: 3,
      hidden: 2,
    );
    expect(pooled, [2.0, 3.0]);
  });

  test('l2Normalize produces unit-length vectors', () {
    final v = Float32List.fromList([3, 4]);
    l2Normalize(values: v, batch: 1, hidden: 2);
    expect(v[0], closeTo(0.6, 1e-6));
    expect(v[1], closeTo(0.8, 1e-6));
  });

  test('cosineSimilarity on unit vectors', () {
    final a = Float32List.fromList([1, 0]);
    final b = Float32List.fromList([0.6, 0.8]);
    expect(cosineSimilarity(a, b), closeTo(0.6, 1e-6));
  });
}
