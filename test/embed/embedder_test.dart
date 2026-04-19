import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:voxsynth/embed/embedder.dart';

double _l2(Float32List v) {
  var s = 0.0;
  for (final x in v) {
    s += x * x;
  }
  return math.sqrt(s);
}

void main() {
  group('FakeEmbedder', () {
    test('embed before load errs', () async {
      final e = FakeEmbedder();
      final r = await e.embedQuery('hi');
      expect(r.isErr, isTrue);
    });

    test('passage output is a L2-unit 384-dim vector by default',
        () async {
      final e = FakeEmbedder();
      await e.load();
      final r = await e.embedPassages(<String>['hello world']);
      expect(r.isOk, isTrue);
      final v = r.okOrNull!.single;
      expect(v.length, 384);
      expect(_l2(v), closeTo(1.0, 1e-4));
    });

    test('is deterministic — identical inputs give identical vectors',
        () async {
      final e = FakeEmbedder();
      await e.load();
      final r1 = (await e.embedQuery('same')).okOrNull!;
      final r2 = (await e.embedQuery('same')).okOrNull!;
      for (var i = 0; i < r1.length; i++) {
        expect(r1[i], r2[i]);
      }
    });

    test('query-prefix vectors differ from passage-prefix vectors for '
        'the same text', () async {
      final e = FakeEmbedder();
      await e.load();
      final q = (await e.embedQuery('same text')).okOrNull!;
      final p =
          (await e.embedPassages(<String>['same text'])).okOrNull!.single;
      // cosine similarity between two unit vectors from different prefixes
      // should not be ~1 — the prefixes change the hash seed.
      final dot = cosineSimilarity(q, p);
      expect(dot, lessThan(0.95));
    });

    test('batch embedPassages returns a vector per input, in order',
        () async {
      final e = FakeEmbedder();
      await e.load();
      final r = await e.embedPassages(<String>['a', 'b', 'c']);
      expect(r.okOrNull, hasLength(3));
      // Each vector is distinct from the others.
      final v = r.okOrNull!;
      expect(cosineSimilarity(v[0], v[1]), isNot(closeTo(1.0, 1e-3)));
      expect(cosineSimilarity(v[1], v[2]), isNot(closeTo(1.0, 1e-3)));
    });

    test('call counter increments per call', () async {
      final e = FakeEmbedder();
      await e.load();
      await e.embedQuery('a');
      await e.embedPassages(<String>['a', 'b']);
      await e.embedQuery('c');
      expect(e.callCount, 3);
    });

    test('dispose blocks further use', () async {
      final e = FakeEmbedder();
      await e.load();
      await e.dispose();
      final r = await e.embedQuery('anything');
      expect(r.isErr, isTrue);
    });

    test('custom embeddingDim is respected', () async {
      final e = FakeEmbedder(embeddingDim: 128);
      await e.load();
      final v = (await e.embedQuery('x')).okOrNull!;
      expect(v.length, 128);
    });
  });

  group('cosineSimilarity', () {
    test('1.0 for identical unit vectors', () {
      final v = Float32List.fromList(<double>[1.0, 0.0, 0.0]);
      expect(cosineSimilarity(v, v), closeTo(1.0, 1e-9));
    });

    test('0.0 for orthogonal unit vectors', () {
      final a = Float32List.fromList(<double>[1.0, 0.0]);
      final b = Float32List.fromList(<double>[0.0, 1.0]);
      expect(cosineSimilarity(a, b), closeTo(0.0, 1e-9));
    });

    test('-1.0 for opposite unit vectors', () {
      final a = Float32List.fromList(<double>[1.0, 0.0]);
      final b = Float32List.fromList(<double>[-1.0, 0.0]);
      expect(cosineSimilarity(a, b), closeTo(-1.0, 1e-9));
    });
  });
}
