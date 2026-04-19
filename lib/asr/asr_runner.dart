import 'dart:typed_data';

import '../core/errors.dart';
import '../core/result.dart';
import 'models/transcript.dart';

/// Offline ASR runner. Given a PCM buffer, returns a [Transcript].
///
/// The original IMPLEMENTATION_PLAN.md §3 spec named this `WhisperRunner`;
/// with the Parakeet-TDT pivot we generalized to `AsrRunner`. Interface
/// semantics are the same: load a model once, transcribe many times,
/// dispose when done.
abstract class AsrRunner {
  /// Load the ASR model(s). For Parakeet-TDT this loads the encoder,
  /// decoder, and joiner ONNX files plus the token vocabulary.
  /// `numThreads` hints at native thread-pool size.
  Future<Result<void, AppError>> load({int numThreads = 4});

  /// Transcribe a buffer of 16 kHz, mono, signed-16-bit little-endian PCM.
  /// [languageHint] is a BCP-47-ish code ("en", "hi"); ignored by
  /// Parakeet-TDT-0.6B-v2 which is English-only, but preserved for
  /// interface stability.
  Future<Result<Transcript, AppError>> transcribe(
    Uint8List pcm16kMono, {
    String? languageHint,
  });

  /// Release native handles. Runner must not be used after this.
  Future<void> dispose();
}

/// An [AsrRunner] that returns scripted [Transcript]s — for unit tests.
///
/// Each call to [transcribe] returns the next entry in [transcripts],
/// cycling when exhausted. If [transcripts] is empty, returns
/// [Transcript.empty].
class FakeAsrRunner implements AsrRunner {
  FakeAsrRunner({this.transcripts = const <Transcript>[]});

  final List<Transcript> transcripts;

  int _cursor = 0;
  bool _loaded = false;
  bool _disposed = false;

  /// Number of [transcribe] calls so far. Useful for tests asserting that
  /// the caller actually invoked the runner.
  int get transcribeCallCount => _cursor;

  @override
  Future<Result<void, AppError>> load({int numThreads = 4}) async {
    if (_disposed) {
      return const Err<void, AppError>(
        UnknownError('FakeAsrRunner already disposed'),
      );
    }
    _loaded = true;
    return const Ok<void, AppError>(null);
  }

  @override
  Future<Result<Transcript, AppError>> transcribe(
    Uint8List pcm16kMono, {
    String? languageHint,
  }) async {
    if (_disposed) {
      return const Err<Transcript, AppError>(
        UnknownError('FakeAsrRunner already disposed'),
      );
    }
    if (!_loaded) {
      return const Err<Transcript, AppError>(
        ModelLoadError('<fake>', reason: 'transcribe called before load'),
      );
    }
    if (transcripts.isEmpty) {
      _cursor++;
      return const Ok<Transcript, AppError>(Transcript.empty);
    }
    final t = transcripts[_cursor % transcripts.length];
    _cursor++;
    return Ok<Transcript, AppError>(t);
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    _loaded = false;
  }
}
