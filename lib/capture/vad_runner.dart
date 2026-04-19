import 'dart:typed_data';

import '../core/errors.dart';
import '../core/result.dart';

/// A voice-activity detector that consumes fixed-size audio frames and
/// returns a speech probability per frame.
///
/// Implementations may carry internal state (Silero v5 has a recurrent
/// hidden state) — callers must feed frames sequentially and [reset] when
/// starting a new utterance/recording.
abstract class VadRunner {
  /// Load the model and allocate inference state. Returns [ModelLoadError]
  /// if the model file is missing or malformed.
  Future<Result<void, AppError>> load();

  /// Classify a single audio frame. [frame] must be exactly [frameSize]
  /// samples of float32 PCM at [sampleRate], normalised to [-1.0, 1.0].
  /// Returns a speech probability in [0.0, 1.0].
  Future<Result<double, AppError>> detect(Float32List frame);

  /// Clear any hidden/streaming state. Call before a fresh recording so
  /// the previous session's trailing state doesn't leak in.
  Future<void> reset();

  /// Release native handles. The runner must not be used after [dispose].
  Future<void> dispose();

  /// Samples per frame the model expects. Silero v5 = 512.
  int get frameSize;

  /// Sample rate of the incoming audio. Always 16000 for VoxSynth.
  int get sampleRate;
}

/// A VAD runner with scripted outputs — for unit tests only.
///
/// Each call to [detect] returns the next value from [probabilities] and
/// advances the cursor. Cycles back to the start when exhausted, so a short
/// script like `[0.9, 0.1]` lets you simulate alternating speech/silence
/// indefinitely.
class FakeVadRunner implements VadRunner {
  FakeVadRunner({
    required this.probabilities,
    this.frameSize = 512,
    this.sampleRate = 16000,
  }) : assert(probabilities.isNotEmpty, 'probabilities must not be empty');

  final List<double> probabilities;

  @override
  final int frameSize;

  @override
  final int sampleRate;

  int _cursor = 0;
  bool _loaded = false;
  bool _disposed = false;

  /// Number of [detect] calls received so far. Useful for assertions.
  int get detectCallCount => _cursor;

  @override
  Future<Result<void, AppError>> load() async {
    if (_disposed) {
      return const Err<void, AppError>(
        UnknownError('FakeVadRunner already disposed'),
      );
    }
    _loaded = true;
    return const Ok<void, AppError>(null);
  }

  @override
  Future<Result<double, AppError>> detect(Float32List frame) async {
    if (_disposed) {
      return const Err<double, AppError>(
        UnknownError('FakeVadRunner already disposed'),
      );
    }
    if (!_loaded) {
      return const Err<double, AppError>(
        ModelLoadError('<fake>', reason: 'detect called before load'),
      );
    }
    if (frame.length != frameSize) {
      return Err<double, AppError>(
        UnknownError(
          'frame length ${frame.length} != frameSize $frameSize',
        ),
      );
    }
    final prob = probabilities[_cursor % probabilities.length];
    _cursor++;
    return Ok<double, AppError>(prob);
  }

  @override
  Future<void> reset() async {
    _cursor = 0;
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    _loaded = false;
  }
}
