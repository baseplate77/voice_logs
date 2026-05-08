import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:meta/meta.dart';

import '../../core/logger.dart';
import '../../core/result.dart';
import 'llm_runner.dart';

const _gemmaAssetPath = 'models/gemma/gemma-4-E2B-it.litertlm';
const _runtimeChannel = MethodChannel('com.nj.voxsynth/runtime');

/// Returns whether this process is running in iOS Simulator.
@visibleForTesting
Future<bool> isIosSimulatorRuntime() async {
  if (!Platform.isIOS) return false;
  try {
    return await _runtimeChannel.invokeMethod<bool>('isIosSimulator') ?? false;
  } on MissingPluginException {
    return Platform.environment.containsKey('SIMULATOR_DEVICE_NAME');
  } on Object {
    return false;
  }
}

/// Returns the backend order used while loading Gemma.
@visibleForTesting
List<PreferredBackend> gemmaBackendLoadOrder({
  required PreferredBackend preferredBackend,
  required bool allowCpuFallback,
  required bool isIosSimulator,
}) {
  if (preferredBackend == PreferredBackend.gpu && isIosSimulator) {
    return const [PreferredBackend.cpu];
  }
  if (preferredBackend == PreferredBackend.gpu && allowCpuFallback) {
    return const [PreferredBackend.gpu, PreferredBackend.cpu];
  }
  return [preferredBackend];
}

/// Detects MediaPipe/LiteRT GPU delegate failures that are safe to retry on CPU.
@visibleForTesting
bool isRecoverableGemmaGpuLoadFailure(Object error) {
  final message = error.toString();
  return message.contains('ModifyGraphWithDelegate') ||
      message.contains('LiteRTResourceCalculator') ||
      message.contains('llm_litert_metal_executor') ||
      message.contains('Metal delegate');
}

String _elapsed(Stopwatch watch) {
  final elapsed = watch.elapsed;
  if (elapsed.inSeconds >= 1) {
    final millis = (elapsed.inMilliseconds % 1000).toString().padLeft(3, '0');
    return '${elapsed.inSeconds}.${millis}s';
  }
  return '${elapsed.inMilliseconds}ms';
}

/// `flutter_gemma`-backed [LlmRunner] targeting Gemma 4 E2B IT via
/// LiteRT-LM. Single long-lived inference model; chat sessions are
/// disposable per call so per-prompt state doesn't bleed between logs.
///
/// Gemma inference is strictly serial — a global operation chain serializes
/// load, generate, and unload so the native model is never closed while a
/// session is active.
class GemmaRunner implements LlmRunner {
  GemmaRunner({
    this.maxTokens = 2048,
    this.preferredBackend = PreferredBackend.gpu,
    this.allowCpuFallback = true,
    this.idleTtl = const Duration(seconds: 60),
    this.isIosSimulator = isIosSimulatorRuntime,
  });

  /// Hard cap of 2048 baked into the litertlm bundle — see v1 memory.
  final int maxTokens;
  final PreferredBackend preferredBackend;

  /// Whether GPU delegate load failures should retry on CPU.
  ///
  /// This keeps iOS Simulator usable when MediaPipe's Metal delegate rejects
  /// the graph while preserving GPU as the first choice on real devices.
  final bool allowCpuFallback;
  final Duration idleTtl;
  final Future<bool> Function() isIosSimulator;

  final _log = Logger('gemma');
  InferenceModel? _model;
  PreferredBackend? _activeBackend;
  Future<void>? _activation;
  Future<void> _opChain = Future.value();
  Timer? _idleTimer;

  @override
  Future<Result<void, LlmError>> load() {
    return _runExclusive('load', _loadUnlocked);
  }

  @override
  Future<Result<String, LlmError>> generate(
    String prompt, {
    double temperature = 0.3,
  }) async {
    return _runExclusive('generate', () async {
      final total = Stopwatch()..start();
      _log.i(
        'Generate start backend=$_activeBackend promptChars=${prompt.length} '
        'temperature=$temperature',
      );
      final loadWatch = Stopwatch()..start();
      final loaded = await _loadUnlocked();
      _log.d('Generate load/ensure-ready took ${_elapsed(loadWatch)}');
      switch (loaded) {
        case Ok():
          break;
        case Err(:final error):
          return Err(error);
      }
      final model = _model;
      if (model == null) {
        return const Err(
          LlmRuntimeError(message: 'Gemma model unavailable after load()'),
        );
      }
      InferenceModelSession? session;
      try {
        final sessionWatch = Stopwatch()..start();
        session = await model.createSession(temperature: temperature);
        _log.i('Gemma session created in ${_elapsed(sessionWatch)}');

        final tokenWatch = Stopwatch()..start();
        try {
          final promptTokens = await session.sizeInTokens(prompt);
          _log.i(
            'Prompt token estimate=$promptTokens '
            'computedIn=${_elapsed(tokenWatch)}',
          );
          final remaining = maxTokens - promptTokens;
          if (remaining < 256) {
            _log.w(
              'Prompt is close to Gemma context cap: maxTokens=$maxTokens, '
              'promptTokens=$promptTokens, remaining=$remaining',
            );
          }
        } on Object catch (e, s) {
          _log.w('Prompt token estimate failed', error: e, stack: s);
        }

        final addWatch = Stopwatch()..start();
        await session.addQueryChunk(Message.text(text: prompt, isUser: true));
        _log.d('Prompt addQueryChunk took ${_elapsed(addWatch)}');

        final generationWatch = Stopwatch()..start();
        final response = StringBuffer();
        var chunks = 0;
        var firstChunkLogged = false;
        await for (final chunk in session.getResponseAsync()) {
          if (!firstChunkLogged) {
            firstChunkLogged = true;
            _log.i(
              'Gemma first token/chunk after ${_elapsed(generationWatch)}',
            );
          }
          chunks++;
          response.write(chunk);
          if (chunks % 50 == 0) {
            _log.d(
              'Gemma generation progress: chunks=$chunks '
              'chars=${response.length} elapsed=${_elapsed(generationWatch)}',
            );
          }
        }
        final text = response.toString();
        _log.i(
          'Gemma generation complete in ${_elapsed(generationWatch)}; '
          'chunks=$chunks responseChars=${text.length}',
        );
        try {
          final responseTokens = await session.sizeInTokens(text);
          _log.i('Response token estimate=$responseTokens');
        } on Object catch (e, s) {
          _log.w('Response token estimate failed', error: e, stack: s);
        }
        _log.i('Generate complete in ${_elapsed(total)}');
        return Ok(text);
      } on Object catch (e, s) {
        return Err(
          LlmRuntimeError(
            message: 'Gemma generate failed: $e',
            cause: e,
            stack: s,
          ),
        );
      } finally {
        final openSession = session;
        if (openSession != null) {
          final closeWatch = Stopwatch()..start();
          try {
            await openSession.close();
            _log.d('Gemma session closed in ${_elapsed(closeWatch)}');
          } on Object catch (e, s) {
            _log.w('Gemma session close failed', error: e, stack: s);
          }
        }
        _scheduleIdleUnload();
      }
    });
  }

  Future<void> _ensureModelInstalledAndActive() {
    final existing = _activation;
    if (existing != null) return existing;

    final activationWatch = Stopwatch()..start();
    _log.i('Ensuring Gemma model asset is installed/active');
    final activation =
        FlutterGemma.installModel(
              modelType: ModelType.gemmaIt,
              fileType: ModelFileType.litertlm,
            )
            .fromAsset(_gemmaAssetPath)
            .install()
            .then((installation) {
              _log.i(
                'Gemma active model: ${installation.modelId} '
                'activationTime=${_elapsed(activationWatch)}',
              );
            })
            .catchError((Object error) {
              _activation = null;
              throw error;
            });

    _activation = activation;
    return activation;
  }

  void _scheduleIdleUnload() {
    _idleTimer?.cancel();
    if (idleTtl <= Duration.zero) return;
    _idleTimer = Timer(idleTtl, () async {
      await unload();
    });
  }

  Future<Result<void, LlmError>> _loadUnlocked() async {
    _idleTimer?.cancel();
    if (_model != null) return const Ok(null);
    try {
      final total = Stopwatch()..start();
      await _ensureModelInstalledAndActive();
      final runningInIosSimulator = await isIosSimulator();
      if (preferredBackend == PreferredBackend.gpu && runningInIosSimulator) {
        _log.i(
          'iOS Simulator detected; using CPU backend because MediaPipe '
          'LiteRT Metal GPU delegates are not reliable in Simulator',
        );
      }
      Object? lastError;
      StackTrace? lastStack;
      for (final backend in gemmaBackendLoadOrder(
        preferredBackend: preferredBackend,
        allowCpuFallback: allowCpuFallback,
        isIosSimulator: runningInIosSimulator,
      )) {
        try {
          final backendWatch = Stopwatch()..start();
          _log.i('Loading Gemma backend=$backend maxTokens=$maxTokens');
          _model = await FlutterGemma.getActiveModel(
            maxTokens: maxTokens,
            preferredBackend: backend,
          );
          _activeBackend = backend;
          _log.i(
            'Gemma loaded (maxTokens=$maxTokens, backend=$backend) '
            'backendLoadTime=${_elapsed(backendWatch)} '
            'totalLoadTime=${_elapsed(total)}',
          );
          return const Ok(null);
        } on Object catch (e, s) {
          lastError = e;
          lastStack = s;
          if (backend == PreferredBackend.gpu &&
              allowCpuFallback &&
              isRecoverableGemmaGpuLoadFailure(e)) {
            _log.w(
              'Gemma GPU load failed; retrying with CPU backend',
              error: e,
              stack: s,
            );
            continue;
          }
          break;
        }
      }
      return Err(
        LlmLoadFailed(
          message: 'Gemma load failed: $lastError',
          cause: lastError,
          stack: lastStack,
        ),
      );
    } on Object catch (e, s) {
      return Err(
        LlmLoadFailed(message: 'Gemma load failed: $e', cause: e, stack: s),
      );
    }
  }

  Future<T> _runExclusive<T>(String operation, Future<T> Function() action) {
    final waitWatch = Stopwatch()..start();
    final previous = _opChain;
    final done = Completer<void>();
    _opChain = done.future;
    return () async {
      try {
        await previous;
      } on Object {
        // Prior operations convert failures to Result values or log them.
      }
      if (waitWatch.elapsedMilliseconds > 10) {
        _log.d('$operation waited ${_elapsed(waitWatch)} for prior Gemma op');
      }
      try {
        return await action();
      } finally {
        done.complete();
      }
    }();
  }

  @override
  Future<void> unload() {
    return _runExclusive('unload', _unloadUnlocked);
  }

  Future<void> _unloadUnlocked() async {
    _idleTimer?.cancel();
    _idleTimer = null;
    final model = _model;
    if (model == null) return;
    try {
      await model.close();
      _log.i('Gemma unloaded');
    } on Object catch (e, s) {
      _log.w('Gemma unload failed', error: e, stack: s);
    } finally {
      if (identical(_model, model)) {
        _model = null;
        _activeBackend = null;
      }
    }
  }

  @override
  Future<void> dispose() async {
    await unload();
  }
}
