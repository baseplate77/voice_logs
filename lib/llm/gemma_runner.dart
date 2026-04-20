// coverage:ignore-file
//
// Placeholder [LlmRunner] left in place after the Rust/candle Gemma
// implementation was removed. The next iteration wires this class to
// `flutter_gemma` (MediaPipe) — until then, every method returns a
// clear "pending" error so the cleanup stage in DebugRunNotifier
// surfaces the gap instead of silently failing or crashing.
//
// The file intentionally keeps the `GemmaRunner(modelPath, tokenizerPath)`
// constructor shape so the call sites (lib/ui/debug/debug_run_notifier.dart
// and the Phase 3 CleanupPipeline) don't need to change. When flutter_gemma
// lands, `modelPath` will point to a `.task` bundle and `tokenizerPath`
// will be ignored (MediaPipe packs the tokenizer into the bundle).

import '../core/errors.dart';
import '../core/result.dart';
import 'llm_runner.dart';

const _pendingReason =
    'Gemma inference is pending the flutter_gemma swap. The Rust/candle '
    'implementation was removed; place a gemma3-270m-it-*.task file under '
    'assets/models/gemma/ and wire flutter_gemma to finish the migration.';

/// Stub [LlmRunner]. Always returns [ModelLoadError] so the cleanup
/// stage fails with a readable message.
class GemmaRunner implements LlmRunner {
  GemmaRunner({required this.modelPath, required this.tokenizerPath});

  /// Kept for interface compatibility. Pointed at a `.gguf` today, will
  /// point at a `.task` once flutter_gemma is wired.
  final String modelPath;

  /// Kept for interface compatibility. Unused once flutter_gemma lands
  /// (MediaPipe bundles the tokenizer inside the `.task` file).
  final String tokenizerPath;

  @override
  Future<Result<void, AppError>> load({
    int maxTokens = 2048,
    double temperature = 0.3,
  }) async {
    return const Err<void, AppError>(
      ModelLoadError('gemma', reason: _pendingReason),
    );
  }

  @override
  Stream<String> generate(
    String prompt, {
    double? temperatureOverride,
  }) async* {
    throw StateError(_pendingReason);
  }

  @override
  Future<Result<String, AppError>> generateSync(
    String prompt, {
    double? temperatureOverride,
  }) async {
    return const Err<String, AppError>(UnknownError(_pendingReason));
  }

  @override
  Future<void> dispose() async {
    // nothing to release — no model was ever loaded.
  }
}
