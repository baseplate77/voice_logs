// coverage:ignore-file
//
// ParakeetRunner is the Rust-backed AsrRunner. Its whole surface calls
// through flutter_rust_bridge into native sherpa-onnx — unit tests can't
// exercise it without the real ONNX model and the Rust dynamic library
// loaded into the test harness. Use FakeAsrRunner for orchestration
// tests; ParakeetRunner is covered end-to-end by the Phase 2b integration
// test that runs on device.

import 'dart:typed_data';

import '../core/errors.dart';
import '../core/result.dart';
import '../src/rust/api/asr.dart' as rust;
import '../src/rust/frb_generated.dart' as frb;
import 'asr_runner.dart';
import 'models/transcript.dart';

/// Production [AsrRunner] that drives Parakeet-TDT via Rust + sherpa-rs.
///
/// Model files are expected to live under [modelDir] in the sherpa-onnx
/// NeMo transducer layout (see Rust-side docstring). The Rust side holds
/// the native recognizer in a process-global slot; this Dart class is the
/// thin orchestrator — it owns lifecycle, never the native handles.
class ParakeetRunner implements AsrRunner {
  ParakeetRunner({required this.modelDir});

  /// Directory containing `encoder.int8.onnx`, `decoder.int8.onnx`,
  /// `joiner.int8.onnx`, `tokens.txt`.
  final String modelDir;

  bool _loaded = false;
  bool _disposed = false;

  @override
  Future<Result<void, AppError>> load({int numThreads = 4}) async {
    if (_disposed) {
      return const Err<void, AppError>(
        ModelLoadError('parakeet', reason: 'runner already disposed'),
      );
    }
    try {
      if (!frb.RustLib.instance.initialized) {
        await frb.RustLib.init();
      }
      await rust.loadParakeet(modelDir: modelDir, numThreads: numThreads);
      _loaded = true;
      return const Ok<void, AppError>(null);
    } on Object catch (e, st) {
      return Err<void, AppError>(
        ModelLoadError(
          modelDir,
          reason: 'Rust loadParakeet failed',
          cause: e,
          stackTrace: st,
        ),
      );
    }
  }

  @override
  Future<Result<Transcript, AppError>> transcribe(
    Uint8List pcm16kMono, {
    String? languageHint,
  }) async {
    if (_disposed) {
      return const Err<Transcript, AppError>(
        UnknownError('ParakeetRunner already disposed'),
      );
    }
    if (!_loaded) {
      return const Err<Transcript, AppError>(
        ModelLoadError(
          'parakeet',
          reason: 'transcribe called before load',
        ),
      );
    }
    try {
      final dto = await rust.transcribePcmS16Le(pcm: pcm16kMono);
      return Ok<Transcript, AppError>(
        Transcript(
          text: dto.text,
          // sherpa-rs 0.6 does not surface word timings through
          // `transcribe`; we leave the list empty for now. When we upgrade
          // to a sherpa-rs release that exposes them (or drop to the C
          // bindings), populate here without touching the public API.
          words: const <Word>[],
          detectedLanguage: dto.detectedLanguage,
        ),
      );
    } on Object catch (e, st) {
      return Err<Transcript, AppError>(
        UnknownError(
          'Parakeet transcribe failed',
          cause: e,
          stackTrace: st,
        ),
      );
    }
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    _loaded = false;
    try {
      await rust.dispose();
    } on Object catch (_) {
      // best-effort — the native side drops regardless on shutdown.
    }
  }
}
