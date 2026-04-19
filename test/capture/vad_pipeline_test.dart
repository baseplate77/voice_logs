import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:voxsynth/capture/vad_pipeline.dart';
import 'package:voxsynth/capture/vad_runner.dart';

/// One frame = 512 samples × 2 bytes/sample = 1024 bytes.
const int _bytesPerFrame = 512 * 2;

Uint8List _framesOfBytes(int count) => Uint8List(count * _bytesPerFrame);

void main() {
  group('VadPipeline', () {
    test('feed before load returns a typed error', () async {
      final runner = FakeVadRunner(probabilities: const <double>[0.9]);
      final pipeline = VadPipeline(runner: runner);

      final r = await pipeline.feed(Uint8List(_bytesPerFrame));
      expect(r.isErr, isTrue);
    });

    test('reframes arbitrarily sized chunks into 512-sample windows', () async {
      final runner = FakeVadRunner(probabilities: const <double>[0.9]);
      final pipeline = VadPipeline(runner: runner);
      await pipeline.load();

      // Feed 5 full frames in awkward sizes.
      await pipeline.feed(_framesOfBytes(1).sublist(0, 500));
      await pipeline.feed(_framesOfBytes(1).sublist(0, _bytesPerFrame));
      await pipeline.feed(_framesOfBytes(3));
      await pipeline.feed(_framesOfBytes(1).sublist(500));
      // Total bytes fed: 500 + 1024 + 3072 + 524 = 5120 = 5 frames.
      expect(runner.detectCallCount, 5);

      await pipeline.dispose();
    });

    test('emits segments driven by scripted probabilities', () async {
      // 15 voiced frames then silence: should emit one segment.
      final probs = List<double>.generate(15, (_) => 0.9)
        ..addAll(List<double>.generate(20, (_) => 0.0));

      final runner = FakeVadRunner(probabilities: probs);
      final pipeline = VadPipeline(runner: runner);
      await pipeline.load();

      final r = await pipeline.feed(_framesOfBytes(probs.length));
      expect(r.isOk, isTrue);
      final segs = r.okOrNull!;
      expect(segs, hasLength(1));
      expect(segs.first.startMs, 0);

      await pipeline.dispose();
    });

    test('dispose makes subsequent feed fail', () async {
      final runner = FakeVadRunner(probabilities: const <double>[0.5]);
      final pipeline = VadPipeline(runner: runner);
      await pipeline.load();
      await pipeline.dispose();
      final r = await pipeline.feed(_framesOfBytes(1));
      expect(r.isErr, isTrue);
    });
  });
}
