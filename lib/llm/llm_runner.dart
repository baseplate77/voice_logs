import '../core/errors.dart';
import '../core/result.dart';

/// On-device LLM runner. Interface first designed for Gemma (per the
/// IMPLEMENTATION_PLAN §4 "GemmaRunner" shape), kept model-agnostic so
/// we can swap the backend without touching the cleanup pipeline.
///
/// Lifecycle: [load] once, [generate] or [generateSync] many times, then
/// [dispose]. The runner owns the model weights; callers own prompts.
abstract class LlmRunner {
  /// Load the model. `maxTokens` is the total context window
  /// (prompt + output) the runner is prepared to accept; `temperature`
  /// is the default sampling temperature, overridable per call.
  ///
  /// Default is 2048 — the hard ceiling baked into
  /// `litert-community/gemma-4-E2B-it-litert-lm`. Asking for more
  /// fails inside LiteRT-LM's engine constructor with
  /// `Failed to create engine: INTERNAL: ERROR`. If a future model
  /// drop raises this ceiling, bump it here; callers that need more
  /// headroom should shrink the prompt or chunk long inputs rather
  /// than exceed the compiled max.
  Future<Result<void, AppError>> load({
    int maxTokens = 2048,
    double temperature = 0.3,
  });

  /// Token-by-token stream. Use for interactive UX (Phase 6 RAG answers).
  /// Closes when the model emits EOS or hits `maxTokens`.
  Stream<String> generate(String prompt, {double? temperatureOverride});

  /// Buffered one-shot generation. Use for deterministic tasks
  /// (cleanup, entity extraction). Returns the full completion text.
  Future<Result<String, AppError>> generateSync(
    String prompt, {
    double? temperatureOverride,
  });

  /// Release native handles. Runner must not be used after this.
  Future<void> dispose();
}

/// Scripted LLM for unit tests.
///
/// Two dispatch modes, picked at construction time:
///
/// 1. **Positional** (default): each [generateSync] call returns the
///    next entry in [responses] (cycles when exhausted). Simple but
///    fragile once the pipeline runs calls concurrently — microtask
///    ordering leaks into test setup.
/// 2. **Keyed** (pass `keyedResponses`): each call is matched against
///    the first keyword whose substring appears in the prompt, and the
///    next response from that key's queue is returned. Cursors are
///    per-key so `["bad", "good"]` still models a retry. This mode is
///    robust to concurrent kick-off since response selection depends on
///    prompt content, not order.
///
/// [generate] emits each response chunk-by-chunk (every 8 characters)
/// to simulate streaming. Pass `errorAfter: N` to turn the (N+1)th call
/// and later into an [Err] — useful for testing retry paths.
class FakeLlmRunner implements LlmRunner {
  FakeLlmRunner({
    this.responses = const <String>[],
    this.errorAfter,
    this.streamChunkSize = 8,
    Map<String, List<String>>? keyedResponses,
  }) : _keyedResponses = keyedResponses;

  final List<String> responses;
  final int? errorAfter;
  final int streamChunkSize;

  /// Keyword → ordered response list. A prompt matches the first
  /// keyword whose substring is present; `null` means positional mode.
  final Map<String, List<String>>? _keyedResponses;
  final Map<String, int> _keyedCursors = <String, int>{};

  int _cursor = 0;
  bool _loaded = false;
  bool _disposed = false;

  /// Number of generate/generateSync calls received. Useful for
  /// assertions about retry counts.
  int get callCount => _cursor;

  String _nextResponse([String? prompt]) {
    final keyed = _keyedResponses;
    if (keyed != null && prompt != null) {
      for (final entry in keyed.entries) {
        if (prompt.contains(entry.key)) {
          final list = entry.value;
          if (list.isEmpty) return '';
          final idx = _keyedCursors[entry.key] ?? 0;
          _keyedCursors[entry.key] = idx + 1;
          return list[idx % list.length];
        }
      }
      return '';
    }
    if (responses.isEmpty) return '';
    return responses[_cursor % responses.length];
  }

  @override
  Future<Result<void, AppError>> load({
    int maxTokens = 2048,
    double temperature = 0.3,
  }) async {
    if (_disposed) {
      return const Err<void, AppError>(
        UnknownError('FakeLlmRunner already disposed'),
      );
    }
    _loaded = true;
    return const Ok<void, AppError>(null);
  }

  @override
  Stream<String> generate(
    String prompt, {
    double? temperatureOverride,
  }) async* {
    if (_disposed || !_loaded) {
      throw StateError(
        'FakeLlmRunner.generate called before load or after dispose',
      );
    }
    final response = _nextResponse(prompt);
    final shouldErr = errorAfter != null && _cursor >= errorAfter!;
    _cursor++;
    if (shouldErr) {
      throw StateError('scripted error from FakeLlmRunner');
    }
    for (var i = 0; i < response.length; i += streamChunkSize) {
      final end =
          (i + streamChunkSize).clamp(0, response.length).toInt();
      yield response.substring(i, end);
    }
  }

  @override
  Future<Result<String, AppError>> generateSync(
    String prompt, {
    double? temperatureOverride,
  }) async {
    if (_disposed) {
      return const Err<String, AppError>(
        UnknownError('FakeLlmRunner already disposed'),
      );
    }
    if (!_loaded) {
      return const Err<String, AppError>(
        ModelLoadError('<fake>', reason: 'generateSync called before load'),
      );
    }
    final response = _nextResponse(prompt);
    final shouldErr = errorAfter != null && _cursor >= errorAfter!;
    _cursor++;
    if (shouldErr) {
      return const Err<String, AppError>(
        UnknownError('scripted error from FakeLlmRunner'),
      );
    }
    return Ok<String, AppError>(response);
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    _loaded = false;
  }
}
