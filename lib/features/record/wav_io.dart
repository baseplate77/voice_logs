import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Metadata for a mono PCM16 RIFF/WAVE file.
class Pcm16WavInfo {
  const Pcm16WavInfo({
    required this.sampleRate,
    required this.channels,
    required this.dataOffset,
    required this.dataBytes,
  });

  /// Samples per second.
  final int sampleRate;

  /// Channel count. VoxSynth records mono audio.
  final int channels;

  /// Byte offset where PCM payload begins.
  final int dataOffset;

  /// Number of PCM payload bytes.
  final int dataBytes;
}

/// Build a 44-byte RIFF/WAVE header for PCM16 audio.
Uint8List pcm16WavHeader({
  required int pcmDataBytes,
  required int sampleRate,
  required int channels,
}) {
  final byteRate = sampleRate * channels * 2;
  final blockAlign = channels * 2;
  final totalSize = 36 + pcmDataBytes;
  final header = ByteData(44);

  void writeAscii(int offset, String value) {
    for (var i = 0; i < value.length; i++) {
      header.setUint8(offset + i, value.codeUnitAt(i));
    }
  }

  writeAscii(0, 'RIFF');
  header.setUint32(4, totalSize, Endian.little);
  writeAscii(8, 'WAVE');
  writeAscii(12, 'fmt ');
  header.setUint32(16, 16, Endian.little);
  header.setUint16(20, 1, Endian.little);
  header.setUint16(22, channels, Endian.little);
  header.setUint32(24, sampleRate, Endian.little);
  header.setUint32(28, byteRate, Endian.little);
  header.setUint16(32, blockAlign, Endian.little);
  header.setUint16(34, 16, Endian.little);
  writeAscii(36, 'data');
  header.setUint32(40, pcmDataBytes, Endian.little);

  return header.buffer.asUint8List();
}

/// Rewrite the RIFF/WAVE header of [path] with the final PCM payload length.
Future<void> patchPcm16WavHeader(
  String path, {
  required int pcmDataBytes,
  required int sampleRate,
  required int channels,
}) async {
  // `writeOnly` truncates the recording; append-capable mode preserves the
  // payload while RandomAccessFile.setPosition(0) lets us rewrite the header.
  final file = await File(path).open(mode: FileMode.writeOnlyAppend);
  try {
    await file.setPosition(0);
    await file.writeFrom(
      pcm16WavHeader(
        pcmDataBytes: pcmDataBytes,
        sampleRate: sampleRate,
        channels: channels,
      ),
    );
  } finally {
    await file.close();
  }
}

/// Parse [path] as a mono PCM16 RIFF/WAVE file.
Future<Pcm16WavInfo> readPcm16WavInfo(String path) async {
  final file = File(path);
  final length = await file.length();
  final raf = await file.open();
  try {
    if (length < 44) {
      throw const FormatException('WAV file is too small.');
    }

    final riff = await raf.read(12);
    if (_ascii(riff, 0, 4) != 'RIFF' || _ascii(riff, 8, 4) != 'WAVE') {
      throw const FormatException('Expected RIFF/WAVE header.');
    }

    var offset = 12;
    int? sampleRate;
    int? channels;
    int? dataOffset;
    int? dataBytes;
    var sawPcm16 = false;

    while (offset + 8 <= length) {
      await raf.setPosition(offset);
      final chunkHeader = await raf.read(8);
      if (chunkHeader.length < 8) break;
      final chunkId = _ascii(chunkHeader, 0, 4);
      final chunkSize = ByteData.sublistView(
        chunkHeader,
      ).getUint32(4, Endian.little);
      final payloadOffset = offset + 8;

      if (chunkId == 'fmt ') {
        await raf.setPosition(payloadOffset);
        final fmt = await raf.read(chunkSize < 16 ? chunkSize : 16);
        if (fmt.length < 16) {
          throw const FormatException('Invalid WAV fmt chunk.');
        }
        final fmtData = ByteData.sublistView(fmt);
        final audioFormat = fmtData.getUint16(0, Endian.little);
        channels = fmtData.getUint16(2, Endian.little);
        sampleRate = fmtData.getUint32(4, Endian.little);
        final bitsPerSample = fmtData.getUint16(14, Endian.little);
        sawPcm16 = audioFormat == 1 && bitsPerSample == 16;
      } else if (chunkId == 'data') {
        dataOffset = payloadOffset;
        dataBytes = chunkSize;
      }

      offset = payloadOffset + chunkSize + (chunkSize.isOdd ? 1 : 0);
    }

    if (!sawPcm16 || sampleRate == null || channels == null) {
      throw const FormatException('Expected PCM16 WAV audio.');
    }
    if (channels != 1) {
      throw FormatException(
        'Expected mono WAV audio, found $channels channels.',
      );
    }
    if (dataOffset == null || dataBytes == null) {
      throw const FormatException('WAV data chunk not found.');
    }

    return Pcm16WavInfo(
      sampleRate: sampleRate,
      channels: channels,
      dataOffset: dataOffset,
      dataBytes: dataBytes,
    );
  } finally {
    await raf.close();
  }
}

/// Stream normalized float samples from a mono PCM16 WAV without loading the
/// whole recording into memory.
Stream<Float32List> readPcm16WavFloatChunks(
  String path, {
  required int samplesPerChunk,
}) async* {
  if (samplesPerChunk <= 0) {
    throw ArgumentError.value(samplesPerChunk, 'samplesPerChunk');
  }

  final info = await readPcm16WavInfo(path);
  final raf = await File(path).open();
  try {
    await raf.setPosition(info.dataOffset);
    var remaining = info.dataBytes;
    final bytesPerChunk = samplesPerChunk * info.channels * 2;

    while (remaining > 0) {
      final wanted = remaining < bytesPerChunk ? remaining : bytesPerChunk;
      final alignedWanted = wanted.isOdd ? wanted - 1 : wanted;
      if (alignedWanted <= 0) break;
      final bytes = await raf.read(alignedWanted);
      if (bytes.isEmpty) break;
      remaining -= bytes.length;
      yield pcm16BytesToFloat32(bytes);
    }
  } finally {
    await raf.close();
  }
}

/// Convert little-endian signed PCM16 bytes to normalized float samples.
Float32List pcm16BytesToFloat32(Uint8List bytes) {
  final sampleCount = bytes.length ~/ 2;
  final out = Float32List(sampleCount);
  final data = ByteData.sublistView(bytes);
  for (var i = 0; i < sampleCount; i++) {
    out[i] = data.getInt16(i * 2, Endian.little) / 32768.0;
  }
  return out;
}

String _ascii(Uint8List bytes, int offset, int length) {
  return ascii.decode(bytes.sublist(offset, offset + length));
}
