import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:voxsynth/features/record/wav_io.dart';

void main() {
  test(
    'pcm16WavHeader writes sizes and readPcm16WavInfo parses them',
    () async {
      final dir = Directory.systemTemp.createTempSync('voxsynth_wav_test_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = '${dir.path}/sample.wav';
      final pcm = Uint8List.fromList([
        0x00, 0x00, // 0
        0xff, 0x7f, // 32767
        0x00, 0x80, // -32768
        0x00, 0x40, // 16384
      ]);

      final file = File(path);
      await file.writeAsBytes([
        ...pcm16WavHeader(
          pcmDataBytes: pcm.length,
          sampleRate: 16000,
          channels: 1,
        ),
        ...pcm,
      ]);

      final info = await readPcm16WavInfo(path);

      expect(info.sampleRate, 16000);
      expect(info.channels, 1);
      expect(info.dataOffset, 44);
      expect(info.dataBytes, pcm.length);
    },
  );

  test('readPcm16WavFloatChunks streams bounded normalized samples', () async {
    final dir = Directory.systemTemp.createTempSync('voxsynth_wav_test_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = '${dir.path}/sample.wav';
    final pcm = Uint8List.fromList([
      0x00, 0x00, // 0
      0xff, 0x7f, // 32767
      0x00, 0x80, // -32768
      0x00, 0x40, // 16384
    ]);
    await File(path).writeAsBytes([
      ...pcm16WavHeader(
        pcmDataBytes: pcm.length,
        sampleRate: 16000,
        channels: 1,
      ),
      ...pcm,
    ]);

    final chunks = await readPcm16WavFloatChunks(
      path,
      samplesPerChunk: 2,
    ).toList();

    expect(chunks, hasLength(2));
    expect(chunks[0], hasLength(2));
    expect(chunks[0][0], 0);
    expect(chunks[0][1], closeTo(32767 / 32768, 1e-6));
    expect(chunks[1][0], -1);
    expect(chunks[1][1], 0.5);
  });

  test('patchPcm16WavHeader updates a streamed recording header', () async {
    final dir = Directory.systemTemp.createTempSync('voxsynth_wav_test_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = '${dir.path}/streamed.wav';
    final pcm = Uint8List.fromList([0x00, 0x00, 0xff, 0x7f]);
    final sink = File(path).openWrite();
    sink.add(pcm16WavHeader(pcmDataBytes: 0, sampleRate: 16000, channels: 1));
    sink.add(pcm);
    await sink.close();

    await patchPcm16WavHeader(
      path,
      pcmDataBytes: pcm.length,
      sampleRate: 16000,
      channels: 1,
    );

    final info = await readPcm16WavInfo(path);
    expect(info.dataBytes, pcm.length);
    expect(await File(path).length(), 44 + pcm.length);
  });
}
