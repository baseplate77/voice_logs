@Tags(<String>['integration'])
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:voxsynth/asr/parakeet_runner.dart';

/// End-to-end Parakeet test. Runs on host via:
///
/// ```
/// cd rust/voxsynth_asr && cargo build --release
/// cd ../.. && flutter test --tags integration test/asr/
/// ```
///
/// Skipped in the default unit suite because it needs:
/// - the Rust cdylib built (`rust/voxsynth_asr/target/release/`)
/// - Parakeet model at `assets/models/parakeet/` (via `scripts/fetch_models.sh`)
///
/// Assertions are deliberately loose. We don't check exact transcript
/// text — only that the pipeline returns *something* plausible for the
/// sherpa-onnx bundled fixture (`test_wavs/0.wav`, ~7 s English speech).
void main() {
  group('ParakeetRunner end-to-end', () {
    final modelDir = '${Directory.current.path}/assets/models/parakeet';
    final wavPath = '$modelDir/test_wavs/0.wav';

    test('load + transcribe a 16 kHz WAV returns English text', () async {
      if (!File('$modelDir/encoder.int8.onnx').existsSync() ||
          !File(wavPath).existsSync()) {
        markTestSkipped(
          'Parakeet model not present at $modelDir — run scripts/fetch_models.sh '
          'to opt into this test.',
        );
        return;
      }
      final runner = ParakeetRunner(modelDir: modelDir);

      final loadResult = await runner.load();
      expect(
        loadResult.isOk,
        isTrue,
        reason: 'load failed: ${loadResult.errOrNull}',
      );

      final pcm = _readWavAsS16le(File(wavPath));

      final transcribeResult = await runner.transcribe(pcm);
      expect(
        transcribeResult.isOk,
        isTrue,
        reason: 'transcribe failed: ${transcribeResult.errOrNull}',
      );
      final transcript = transcribeResult.okOrNull!;

      expect(transcript.text, isNotEmpty);
      expect(transcript.text.length, greaterThan(3));
      expect(transcript.detectedLanguage, 'en');

      await runner.dispose();
    }, timeout: const Timeout(Duration(minutes: 2)));
  });
}

/// Parse a standard 16 kHz mono 16-bit PCM RIFF/WAVE file into s16le bytes.
///
/// Handles extra RIFF chunks before `data` (LIST, fact, etc.) by scanning
/// chunk-by-chunk instead of assuming the header is exactly 44 bytes.
/// The sherpa-onnx test fixtures are plain 44-byte-header PCM but some
/// WAVE writers insert metadata chunks.
Uint8List _readWavAsS16le(File f) {
  final bytes = f.readAsBytesSync();
  if (bytes.length < 44) {
    throw FormatException('WAV too short: ${bytes.length} bytes');
  }
  final view = ByteData.sublistView(bytes);

  final riff = String.fromCharCodes(bytes.sublist(0, 4));
  final wave = String.fromCharCodes(bytes.sublist(8, 12));
  if (riff != 'RIFF' || wave != 'WAVE') {
    throw FormatException('Not a RIFF/WAVE file: $riff/$wave');
  }

  // Walk chunks starting at offset 12.
  var pos = 12;
  int? sampleRate;
  int? channels;
  int? bitsPerSample;
  int? audioFormat;
  int? dataStart;
  int? dataLen;
  while (pos + 8 <= bytes.length) {
    final id = String.fromCharCodes(bytes.sublist(pos, pos + 4));
    final size = view.getUint32(pos + 4, Endian.little);
    final body = pos + 8;
    if (id == 'fmt ') {
      audioFormat = view.getUint16(body, Endian.little);
      channels = view.getUint16(body + 2, Endian.little);
      sampleRate = view.getUint32(body + 4, Endian.little);
      bitsPerSample = view.getUint16(body + 14, Endian.little);
    } else if (id == 'data') {
      dataStart = body;
      dataLen = size;
      break;
    }
    pos = body + size + (size.isOdd ? 1 : 0);
  }

  if (dataStart == null || dataLen == null) {
    throw const FormatException('No data chunk in WAV');
  }
  if (audioFormat != 1) {
    throw FormatException('Unsupported WAVE format $audioFormat (want PCM=1)');
  }
  if (channels != 1) {
    throw FormatException('Expected mono, got $channels channels');
  }
  if (sampleRate != 16000) {
    throw FormatException(
      'Expected 16 kHz, got $sampleRate Hz — resampling not implemented',
    );
  }
  if (bitsPerSample != 16) {
    throw FormatException('Expected 16-bit, got $bitsPerSample');
  }

  return Uint8List.sublistView(bytes, dataStart, dataStart + dataLen);
}
