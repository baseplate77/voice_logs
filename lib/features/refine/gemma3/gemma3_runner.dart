import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_gemma/flutter_gemma.dart';

import '../../../core/logger.dart';
import '../../../core/result.dart';
import '../llm_runner.dart';

/// Production [LlmRunner] backed by Gemma 3 1B IT Q4 LiteRT-LM.
///
/// The model bundle is shipped as a Flutter asset and installed into
/// flutter_gemma's private model store on first load. Generation is strictly
/// serialized via [_runExclusive] so refine and memory jobs never overlap LLM
/// inference.
class Gemma3Runner implements LlmRunner, StreamingLlmRunner {
  Gemma3Runner({
    this.assetPath = _defaultAssetPath,
    this.maxTokens = 1024,
    this.idleTtl = const Duration(minutes: 5),
    this.staleNativeRecoveryDelay = const Duration(seconds: 2),
    PreferredBackend? preferredBackend,
    PlatformService? platformService,
  }) : _preferredBackend = preferredBackend,
       _platformService = platformService ?? PlatformService();

  static const _defaultAssetPath =
      'models/gemma/Gemma3-1B-IT_multi-prefill-seq_q4_ekv4096.litertlm';
  static const _runtimeChannel = MethodChannel('com.nj.voxsynth/runtime');

  /// Flutter asset path without the leading `assets/` prefix, as expected by
  /// flutter_gemma's `fromAsset()` source handler.
  final String assetPath;

  /// Context/token budget passed to LiteRT-LM.
  final int maxTokens;

  /// Time to keep the native model loaded after the last generation.
  final Duration idleTtl;

  /// Delay after cancelling an orphaned native generation before retrying.
  final Duration staleNativeRecoveryDelay;

  final PreferredBackend? _preferredBackend;
  final PlatformService _platformService;
  final _log = Logger('gemma3');

  InferenceModel? _model;
  Future<Result<void, LlmError>>? _loading;
  Future<void> _opChain = Future.value();
  Timer? _idleTimer;

  @override
  Future<Result<void, LlmError>> load() {
    return _runExclusive('load', _loadUnlocked);
  }

  Future<Result<void, LlmError>> _loadUnlocked() async {
    _idleTimer?.cancel();
    if (_model != null) return const Ok(null);

    final existing = _loading;
    if (existing != null) return existing;

    final loading = _doLoad();
    _loading = loading;
    final result = await loading;
    _loading = null;
    return result;
  }

  Future<Result<void, LlmError>> _doLoad() async {
    try {
      await FlutterGemma.initialize();
      await _resetNativeRuntime('before first load');

      _log.i('Installing/activating Gemma 3 1B asset $assetPath');
      final installation = await FlutterGemma.installModel(
        modelType: ModelType.gemmaIt,
        fileType: ModelFileType.litertlm,
      ).fromAsset(assetPath).install();
      _log.i('Gemma active model: ${installation.modelId}');

      final backend = _preferredBackend ?? await _defaultBackend();
      _log.i('Loading Gemma 3 1B backend=$backend maxTokens=$maxTokens');
      final watch = Stopwatch()..start();
      try {
        _model = await FlutterGemma.getActiveModel(
          maxTokens: maxTokens,
          preferredBackend: backend,
        );
      } on Object catch (e) {
        if (backend == PreferredBackend.gpu) {
          _log.w('Gemma GPU load failed; retrying CPU', error: e);
          _model = await FlutterGemma.getActiveModel(
            maxTokens: maxTokens,
            preferredBackend: PreferredBackend.cpu,
          );
        } else {
          rethrow;
        }
      }
      _log.i('Gemma 3 1B loaded in ${watch.elapsedMilliseconds} ms');
      return const Ok(null);
    } on Object catch (e, s) {
      return Err(
        LlmLoadFailed(
          message: 'Failed to load Gemma 3 1B: $e',
          cause: e,
          stack: s,
        ),
      );
    }
  }

  @override
  Future<Result<String, LlmError>> generate(
    String prompt, {
    double temperature = 0.3,
  }) {
    return _runExclusive(
      'generate',
      () => _generateUnlocked(prompt, temperature: temperature),
    );
  }

  @override
  Stream<Result<String, LlmError>> generateStream(
    String prompt, {
    double temperature = 0.3,
  }) {
    // ignore: close_sinks, closed by _generateStreamUnlocked after generation.
    late StreamController<Result<String, LlmError>> controller;
    controller = StreamController<Result<String, LlmError>>(
      onListen: () {
        unawaited(
          _runExclusive(
            'generateStream',
            () => _generateStreamUnlocked(
              prompt,
              temperature: temperature,
              controller: controller,
            ),
          ),
        );
      },
    );
    return controller.stream;
  }

  Future<Result<String, LlmError>> _generateUnlocked(
    String prompt, {
    required double temperature,
  }) async {
    final out = StringBuffer();
    LlmError? failure;
    // ignore: close_sinks, closed by _generateStreamUnlocked after generation.
    final controller = StreamController<Result<String, LlmError>>();
    final sub = controller.stream.listen((event) {
      switch (event) {
        case Ok(:final value):
          out.write(value);
        case Err(:final error):
          failure = error;
      }
    });
    await _generateStreamUnlocked(
      prompt,
      temperature: temperature,
      controller: controller,
    );
    await sub.cancel();
    final error = failure;
    if (error != null) return Err(error);
    return Ok(out.toString());
  }

  Future<void> _generateStreamUnlocked(
    String prompt, {
    required double temperature,
    required StreamController<Result<String, LlmError>> controller,
  }) async {
    try {
      var recoveredBusyNativeGeneration = false;
      while (true) {
        final attempt = await _generateStreamAttempt(
          prompt,
          temperature: temperature,
          controller: controller,
        );
        switch (attempt) {
          case _GemmaAttemptSucceeded():
            return;
          case _GemmaAttemptBusy(:final cause, :final stack):
            if (recoveredBusyNativeGeneration) {
              controller.add(Err(_runtimeError(cause, stack)));
              return;
            }
            recoveredBusyNativeGeneration = true;
            _log.w(
              'Gemma native generation already in progress; '
              'cancelling stale session and retrying once',
              error: cause,
              stack: stack,
            );
            await _resetNativeRuntime('native generation busy');
            if (staleNativeRecoveryDelay > Duration.zero) {
              await Future<void>.delayed(staleNativeRecoveryDelay);
            }
          case _GemmaAttemptFailed(:final error):
            controller.add(Err(error));
            return;
        }
      }
    } on Object catch (e, s) {
      controller.add(Err(_runtimeError(e, s)));
    } finally {
      await controller.close();
    }
  }

  Future<_GemmaAttemptResult> _generateStreamAttempt(
    String prompt, {
    required double temperature,
    required StreamController<Result<String, LlmError>> controller,
  }) async {
    final loaded = await _loadUnlocked();
    switch (loaded) {
      case Ok():
        break;
      case Err(:final error):
        return _GemmaAttemptFailed(error);
    }

    final model = _model;
    if (model == null) {
      return const _GemmaAttemptFailed(
        LlmRuntimeError(message: 'Gemma 3 1B model not available after load()'),
      );
    }

    InferenceModelSession? session;
    final watch = Stopwatch()..start();
    var responseChars = 0;
    try {
      session = await model.createSession(temperature: temperature, topP: 0.95);
      await session.addQueryChunk(Message.text(text: prompt, isUser: true));
      await for (final chunk in session.getResponseAsync()) {
        responseChars += chunk.length;
        if (!controller.isClosed) controller.add(Ok(chunk));
      }
      _log.i(
        'Gemma stream done in ${watch.elapsedMilliseconds} ms; '
        'promptChars=${prompt.length} responseChars=$responseChars',
      );
      _armIdleTimer();
      return const _GemmaAttemptSucceeded();
    } on Object catch (e, s) {
      if (_isNativeGenerationBusy(e)) return _GemmaAttemptBusy(e, s);
      return _GemmaAttemptFailed(_runtimeError(e, s));
    } finally {
      try {
        await session?.close();
      } on Object catch (e, s) {
        _log.w('Gemma session close failed', error: e, stack: s);
      }
    }
  }

  @override
  Future<void> unload() {
    return _runExclusiveVoid('unload', _unloadUnlocked);
  }

  Future<void> _unloadUnlocked() async {
    _idleTimer?.cancel();
    _idleTimer = null;
    final model = _model;
    _model = null;
    await model?.close();
  }

  @override
  Future<void> dispose() {
    return unload();
  }

  Future<T> _runExclusive<T>(String label, Future<T> Function() op) {
    final completer = Completer<T>();
    _opChain = _opChain.then((_) async {
      try {
        completer.complete(await op());
      } on Object catch (e, s) {
        _log.w('Gemma operation $label threw', error: e, stack: s);
        completer.completeError(e, s);
      }
    });
    return completer.future;
  }

  Future<void> _runExclusiveVoid(String label, Future<void> Function() op) {
    return _runExclusive(label, op);
  }

  void _armIdleTimer() {
    _idleTimer?.cancel();
    if (idleTtl == Duration.zero) return;
    _idleTimer = Timer(idleTtl, () {
      unawaited(unload());
    });
  }

  Future<void> _resetNativeRuntime(String reason) async {
    _idleTimer?.cancel();
    _idleTimer = null;
    _log.i('Resetting Gemma native runtime: $reason');

    final dartModel = _model ?? FlutterGemmaPlugin.instance.initializedModel;
    _model = null;

    await _bestEffort('stop native generation', () async {
      final session = dartModel?.session;
      if (session != null) await session.stopGeneration();
      await _platformService.stopGeneration();
    });
    await _bestEffort('close native session', () async {
      final session = dartModel?.session;
      if (session != null) await session.close();
      await _platformService.closeSession();
    });
    await _bestEffort('close native model', () async {
      if (dartModel != null) {
        await dartModel.close();
      } else {
        await _platformService.closeModel();
      }
    });
  }

  Future<void> _bestEffort(String label, Future<void> Function() op) async {
    try {
      await op();
    } on Object catch (e, s) {
      if (_isExpectedCleanupMiss(e)) return;
      _log.w('Gemma cleanup step failed: $label', error: e, stack: s);
    }
  }

  bool _isExpectedCleanupMiss(Object error) {
    final text = error.toString();
    return text.contains('Session not created') ||
        text.contains('Inference model is not created') ||
        text.contains('Inference model not created') ||
        text.contains('Model is closed');
  }

  LlmRuntimeError _runtimeError(Object error, StackTrace stack) {
    return LlmRuntimeError(
      message: 'Gemma 3 1B generation failed: $error',
      cause: error,
      stack: stack,
    );
  }

  bool _isNativeGenerationBusy(Object error) {
    if (error is PlatformException && error.code == 'ERROR') {
      final message = error.message ?? '';
      return message.contains('Response generation is already in progress') ||
          message.contains('request in progress');
    }
    final text = error.toString();
    return text.contains('Response generation is already in progress') ||
        text.contains('request in progress');
  }

  Future<PreferredBackend> _defaultBackend() async {
    if (!Platform.isIOS) return PreferredBackend.gpu;
    try {
      final isSimulator =
          await _runtimeChannel.invokeMethod<bool>('isIosSimulator') ?? false;
      return isSimulator ? PreferredBackend.cpu : PreferredBackend.gpu;
    } on Object {
      return Platform.environment.containsKey('SIMULATOR_DEVICE_NAME')
          ? PreferredBackend.cpu
          : PreferredBackend.gpu;
    }
  }
}

sealed class _GemmaAttemptResult {
  const _GemmaAttemptResult();
}

final class _GemmaAttemptSucceeded extends _GemmaAttemptResult {
  const _GemmaAttemptSucceeded();
}

final class _GemmaAttemptBusy extends _GemmaAttemptResult {
  const _GemmaAttemptBusy(this.cause, this.stack);

  final Object cause;
  final StackTrace stack;
}

final class _GemmaAttemptFailed extends _GemmaAttemptResult {
  const _GemmaAttemptFailed(this.error);

  final LlmError error;
}
