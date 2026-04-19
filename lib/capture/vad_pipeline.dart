import 'dart:async';
import 'dart:typed_data';

import '../core/errors.dart';
import '../core/result.dart';
import 'models/speech_segment.dart';
import 'vad_runner.dart';
import 'vad_segmenter.dart';

/// Glues a [VadRunner] to a [VadSegmenter] and exposes a simple
/// `feed(pcm) -> segments` contract.
///
/// Kept pure-Dart (no isolates) so it's directly unit-testable against a
/// [FakeVadRunner]. [VadWorkerIsolate] wraps one of these inside an
/// isolate for production use.
class VadPipeline {
  VadPipeline({
    required this.runner,
    VadSegmenter? segmenter,
  }) : segmenter = segmenter ?? VadSegmenter();

  final VadRunner runner;
  final VadSegmenter segmenter;

  /// PCM bytes received but not yet aligned into a full [VadRunner.frameSize]
  /// frame. Carried across calls so streaming chunks of any size work.
  final BytesBuilder _leftover = BytesBuilder(copy: false);

  bool _loaded = false;

  int get _bytesPerFrame => runner.frameSize * 2; // s16le

  /// Lazily load the runner. Subsequent calls are no-ops.
  Future<Result<void, AppError>> load() async {
    if (_loaded) return const Ok<void, AppError>(null);
    final r = await runner.load();
    if (r.isOk) _loaded = true;
    return r;
  }

  /// Feed a chunk of 16 kHz s16le PCM. Returns any segments that closed as
  /// a result of this chunk.
  ///
  /// Internally reframes the bytes into [VadRunner.frameSize]-sample
  /// windows, runs VAD, and dispatches to the segmenter.
  Future<Result<List<SpeechSegment>, AppError>> feed(Uint8List pcm) async {
    if (!_loaded) {
      return const Err<List<SpeechSegment>, AppError>(
        ModelLoadError('vad', reason: 'feed called before load'),
      );
    }
    final segments = <SpeechSegment>[];

    _leftover.add(pcm);
    while (_leftover.length >= _bytesPerFrame) {
      final buf = _leftover.toBytes();
      final frameBytes = Uint8List.sublistView(buf, 0, _bytesPerFrame);
      final remaining = Uint8List.sublistView(buf, _bytesPerFrame);
      _leftover.clear();
      _leftover.add(remaining);

      final float = _s16leToFloat32(frameBytes);
      final probResult = await runner.detect(float);
      if (probResult.isErr) {
        return Err<List<SpeechSegment>, AppError>(probResult.errOrNull!);
      }
      final emitted = segmenter.feed(
        probability: probResult.okOrNull!,
        framePcmBytes: Uint8List.fromList(frameBytes),
      );
      if (emitted != null) segments.add(emitted);
    }

    return Ok<List<SpeechSegment>, AppError>(segments);
  }

  /// Flush any in-flight segment (call at end of recording).
  SpeechSegment? flush() => segmenter.flush();

  /// Reset state for a new recording. Keeps the model loaded.
  Future<void> reset() async {
    _leftover.clear();
    segmenter.reset();
    await runner.reset();
  }

  /// Release all resources. Pipeline must not be used after this.
  Future<void> dispose() async {
    _leftover.clear();
    await runner.dispose();
    _loaded = false;
  }

  /// Convert s16le bytes to float32 samples in [-1.0, 1.0].
  static Float32List _s16leToFloat32(Uint8List bytes) {
    assert(bytes.length.isEven, 's16le byte length must be even');
    final view = ByteData.sublistView(bytes);
    final n = bytes.length ~/ 2;
    final out = Float32List(n);
    for (var i = 0; i < n; i++) {
      final sample = view.getInt16(i * 2, Endian.little);
      out[i] = sample / 32768.0;
    }
    return out;
  }
}
