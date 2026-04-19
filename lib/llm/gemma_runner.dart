// coverage:ignore-file
//
// GemmaRunner bridges the Dart-side LlmRunner interface to Gemma 3
// running inside voxsynth_asr (candle-transformers). Cannot be
// exercised under `flutter test` — requires the Rust dylib plus the
// real GGUF model on disk. Unit tests use FakeLlmRunner; this is
// covered end-to-end by the host integration test at
// `test/llm/gemma_runner_integration_test.dart`.

import '../core/errors.dart';
import '../core/result.dart';
import '../src/rust/api/llm.dart' as rust;
import '../src/rust/frb_generated.dart' as frb;
import 'llm_runner.dart';

/// Production [LlmRunner] that delegates to the Rust crate.
///
/// Gemma 3 chat format expects prompts wrapped in
/// `<start_of_turn>user … <end_of_turn><start_of_turn>model`. We keep
/// that wrapping at the caller — [CleanupPipeline] could add it once
/// we confirm Gemma 3 1B IT needs it, but the prompt templates as
/// written work fine without (the model treats them as completion-style
/// prompts and emits the right JSON).
class GemmaRunner implements LlmRunner {
  GemmaRunner({required this.modelPath, required this.tokenizerPath});

  /// Absolute path to the GGUF weights file.
  final String modelPath;

  /// Absolute path to `tokenizer.json`.
  final String tokenizerPath;

  int _maxTokens = 2048;
  double _temperature = 0.3;
  bool _loaded = false;
  bool _disposed = false;

  @override
  Future<Result<void, AppError>> load({
    int maxTokens = 2048,
    double temperature = 0.3,
  }) async {
    if (_disposed) {
      return const Err<void, AppError>(
        ModelLoadError('gemma', reason: 'runner already disposed'),
      );
    }
    _maxTokens = maxTokens;
    _temperature = temperature;
    try {
      if (!frb.RustLib.instance.initialized) {
        await frb.RustLib.init();
      }
      await rust.loadGemma(
        modelPath: modelPath,
        tokenizerPath: tokenizerPath,
      );
      _loaded = true;
      return const Ok<void, AppError>(null);
    } on Object catch (e, st) {
      return Err<void, AppError>(
        ModelLoadError(
          modelPath,
          reason: 'Rust loadGemma failed',
          cause: e,
          stackTrace: st,
        ),
      );
    }
  }

  @override
  Stream<String> generate(
    String prompt, {
    double? temperatureOverride,
  }) async* {
    // The Rust side does not expose streaming yet — emit the full
    // completion as one chunk. The LlmRunner contract allows this; it
    // just means callers relying on intermediate tokens will see
    // latency but the full text arrives.
    final r = await generateSync(
      prompt,
      temperatureOverride: temperatureOverride,
    );
    if (r.isErr) {
      throw StateError('GemmaRunner.generate failed: ${r.errOrNull}');
    }
    yield r.okOrNull!;
  }

  @override
  Future<Result<String, AppError>> generateSync(
    String prompt, {
    double? temperatureOverride,
  }) async {
    if (_disposed) {
      return const Err<String, AppError>(
        UnknownError('GemmaRunner already disposed'),
      );
    }
    if (!_loaded) {
      return const Err<String, AppError>(
        ModelLoadError('gemma', reason: 'generate called before load'),
      );
    }
    try {
      final text = await rust.generateSync(
        prompt: prompt,
        maxTokens: _maxTokens,
        temperature: temperatureOverride ?? _temperature,
      );
      return Ok<String, AppError>(text);
    } on Object catch (e, st) {
      return Err<String, AppError>(
        UnknownError(
          'Gemma generateSync failed',
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
      await rust.disposeLlm();
    } on Object catch (_) {
      // best-effort — native side drops on shutdown anyway.
    }
  }
}
