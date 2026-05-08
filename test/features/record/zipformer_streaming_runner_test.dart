import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:voxsynth/features/record/zipformer_streaming_runner.dart';

void main() {
  test('pcm16BytesToFloat32 converts little-endian signed samples', () {
    final bytes = Uint8List.fromList([
      0x00, 0x00, // 0
      0xff, 0x7f, // 32767
      0x00, 0x80, // -32768
      0x00, 0x40, // 16384
    ]);

    final samples = pcm16BytesToFloat32(bytes);

    expect(samples, hasLength(4));
    expect(samples[0], 0);
    expect(samples[1], closeTo(32767 / 32768, 1e-6));
    expect(samples[2], -1);
    expect(samples[3], 0.5);
  });
}
