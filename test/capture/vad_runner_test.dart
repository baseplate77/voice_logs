import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:voxsynth/capture/vad_runner.dart';

void main() {
  group('FakeVadRunner', () {
    test('detect without load errs', () async {
      final runner = FakeVadRunner(probabilities: const <double>[0.9]);
      final out = await runner.detect(Float32List(512));
      expect(out.isErr, isTrue);
    });

    test('returns scripted probabilities in order and cycles', () async {
      final runner = FakeVadRunner(
        probabilities: const <double>[0.1, 0.9, 0.4],
      );
      await runner.load();

      final frame = Float32List(512);
      final seen = <double>[];
      for (var i = 0; i < 6; i++) {
        final r = await runner.detect(frame);
        expect(r.isOk, isTrue);
        seen.add(r.okOrNull!);
      }
      expect(seen, <double>[0.1, 0.9, 0.4, 0.1, 0.9, 0.4]);
    });

    test('rejects wrong frame size', () async {
      final runner = FakeVadRunner(probabilities: const <double>[0.5]);
      await runner.load();

      final r = await runner.detect(Float32List(256));
      expect(r.isErr, isTrue);
    });

    test('reset rewinds the cursor', () async {
      final runner =
          FakeVadRunner(probabilities: const <double>[0.9, 0.1, 0.9]);
      await runner.load();
      final f = Float32List(512);
      await runner.detect(f);
      await runner.detect(f);
      expect(runner.detectCallCount, 2);
      await runner.reset();
      expect(runner.detectCallCount, 0);
      final r = await runner.detect(f);
      expect(r.okOrNull, 0.9);
    });

    test('dispose prevents further use', () async {
      final runner = FakeVadRunner(probabilities: const <double>[0.9]);
      await runner.load();
      await runner.dispose();
      final r = await runner.detect(Float32List(512));
      expect(r.isErr, isTrue);
    });

    test('exposes Silero-compatible frame size and sample rate by default',
        () {
      final runner = FakeVadRunner(probabilities: const <double>[0.5]);
      expect(runner.frameSize, 512);
      expect(runner.sampleRate, 16000);
    });
  });
}
