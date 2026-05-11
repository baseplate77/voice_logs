import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:voxsynth/features/refine/smollm/sampler.dart';

Float32List _logits(List<double> values) => Float32List.fromList(values);

void main() {
  group('sampleToken', () {
    test('temperature == 0 returns argmax', () {
      final logits = _logits([0.1, 9.0, 0.5, 0.2]);
      final id = sampleToken(
        logits: logits,
        vocabSize: logits.length,
        config: const SamplerConfig(temperature: 0),
      );
      expect(id, 1);
    });

    test('temperature > 0 with seed is deterministic', () {
      final logits = _logits([1.0, 0.5, 0.2, 0.1]);
      final ids = List.generate(
        20,
        (_) => sampleToken(
          logits: logits,
          vocabSize: logits.length,
          config: const SamplerConfig(temperature: 1.0, seed: 42),
          rng: math.Random(42),
        ),
      );
      // Same seed → same draw every time.
      expect(ids.toSet(), {ids.first});
    });

    test('top-p truncation excludes the long tail', () {
      // Massive probability mass on token 0; long tail of tiny logits.
      const size = 50;
      final values = List<double>.filled(size, -10.0);
      values[0] = 10.0;
      final logits = _logits(values);
      final rng = math.Random(7);
      for (var i = 0; i < 50; i++) {
        final id = sampleToken(
          logits: logits,
          vocabSize: size,
          config: const SamplerConfig(temperature: 1.0, topP: 0.9),
          rng: rng,
        );
        expect(id, 0);
      }
    });

    test('throws when logits row is shorter than vocabSize', () {
      expect(
        () => sampleToken(
          logits: _logits([1.0, 2.0]),
          vocabSize: 4,
          config: const SamplerConfig(temperature: 0),
        ),
        throwsArgumentError,
      );
    });
  });
}
