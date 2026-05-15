import '../../core/app_error.dart';
import '../../core/result.dart';

/// Errors surfaced across the LLM layer boundary.
sealed class LlmError extends AppError {
  const LlmError({required super.message, super.cause, super.stack});
}

final class LlmModelMissing extends LlmError {
  const LlmModelMissing(String name)
    : super(message: 'LLM model not installed: $name');
}

final class LlmLoadFailed extends LlmError {
  const LlmLoadFailed({required super.message, super.cause, super.stack});
}

final class LlmRuntimeError extends LlmError {
  const LlmRuntimeError({required super.message, super.cause, super.stack});
}

/// Abstract LLM runner. One-shot prompt → response.
///
/// Sampling parameters are exposed so callers can match the model vendor's
/// recommended config (e.g. Gemma 3: temperature=1.0, topK=64, topP=0.95)
/// or force deterministic greedy decoding for structured outputs (refine
/// uses temperature=0.0 + topK=1 so its JSON parses cleanly).
///
/// Important: when [topK] is 1, the sampler picks the single highest-
/// probability token regardless of [temperature]. Passing temperature
/// without raising topK has no effect — and is the classic cause of phrase
/// loops on small models.
abstract class LlmRunner {
  /// Load the model; idempotent.
  Future<Result<void, LlmError>> load();

  /// Run [prompt] and return the full generated response.
  Future<Result<String, LlmError>> generate(
    String prompt, {
    double temperature = 0.3,
    int topK = 1,
    double topP = 0.95,
    int? randomSeed,
  });

  /// Unload model weights from memory while keeping the runner reusable.
  Future<void> unload();

  /// Release native resources.
  Future<void> dispose();
}

/// Optional capability for runners that can surface decode chunks while the
/// model is generating. Callers must still handle plain [LlmRunner] instances
/// by falling back to [LlmRunner.generate].
abstract interface class StreamingLlmRunner {
  /// Run [prompt] and yield text deltas as they are produced.
  Stream<Result<String, LlmError>> generateStream(
    String prompt, {
    double temperature = 0.3,
    int topK = 1,
    double topP = 0.95,
    int? randomSeed,
  });
}
