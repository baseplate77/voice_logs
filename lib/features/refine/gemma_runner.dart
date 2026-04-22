import 'dart:async';

import 'package:flutter_gemma/flutter_gemma.dart';

import '../../core/logger.dart';
import '../../core/result.dart';
import 'llm_runner.dart';

/// `flutter_gemma`-backed [LlmRunner] targeting Gemma 4 E2B IT via
/// LiteRT-LM. Single long-lived inference model; chat sessions are
/// disposable per call so per-prompt state doesn't bleed between logs.
///
/// Gemma inference is strictly serial — a global [_lock] future chain
/// enforces this across the whole app (concurrent sessions OOM on
/// mobile, confirmed in v1).
class GemmaRunner implements LlmRunner {
  GemmaRunner({
    this.maxTokens = 2048,
    this.preferredBackend = PreferredBackend.gpu,
  });

  /// Hard cap of 2048 baked into the litertlm bundle — see v1 memory.
  final int maxTokens;
  final PreferredBackend preferredBackend;

  final _log = Logger('gemma');
  InferenceModel? _model;
  Future<void> _lock = Future.value();

  @override
  Future<Result<void, LlmError>> load() async {
    if (_model != null) return const Ok(null);
    try {
      _model = await FlutterGemma.getActiveModel(
        maxTokens: maxTokens,
        preferredBackend: preferredBackend,
      );
      _log.i('Gemma loaded (maxTokens=$maxTokens, backend=$preferredBackend)');
      return const Ok(null);
    } on Object catch (e, s) {
      return Err(
        LlmLoadFailed(message: 'getActiveModel failed: $e', cause: e, stack: s),
      );
    }
  }

  @override
  Future<Result<String, LlmError>> generate(
    String prompt, {
    double temperature = 0.3,
  }) async {
    final model = _model;
    if (model == null) {
      return const Err(
        LlmRuntimeError(message: 'GemmaRunner.load() not called'),
      );
    }
    // Serialize every caller through the same lock.
    final completer = Completer<Result<String, LlmError>>();
    final prev = _lock;
    _lock = completer.future.then((_) {}).catchError((Object _) {});
    try {
      await prev;
      final session = await model.createSession(
        temperature: temperature,
        topK: 40,
      );
      try {
        await session.addQueryChunk(Message.text(text: prompt, isUser: true));
        final response = await session.getResponse();
        completer.complete(Ok(response));
        return Ok(response);
      } finally {
        await session.close();
      }
    } on Object catch (e, s) {
      final err = LlmRuntimeError(
        message: 'Gemma generate failed: $e',
        cause: e,
        stack: s,
      );
      completer.complete(Err(err));
      return Err(err);
    }
  }

  @override
  Future<void> dispose() async {
    await _model?.close();
    _model = null;
  }
}
