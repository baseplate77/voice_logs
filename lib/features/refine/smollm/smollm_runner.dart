import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';

import '../../../core/logger.dart';
import '../../../core/model_bootstrap.dart';
import '../../../core/result.dart';
import '../llm_runner.dart';
import 'bpe_tokenizer.dart';
import 'chat_template.dart';
import 'kv_cache.dart';
import 'sampler.dart';

/// `flutter_onnxruntime`-backed [LlmRunner] for SmolLM2-360M-Instruct.
///
/// One long-lived ONNX session; one [BpeTokenizer]; one in-flight
/// generation at a time enforced by [_runExclusive] — same serialization
/// rule that protected the old Gemma path. Idle for [idleTtl] without a
/// generate call → unload to release the session's mmap.
///
/// The decode loop owns the KV cache: prefill on the full prompt, then
/// autoregressive single-token steps feeding each step's `present.*`
/// outputs back as the next step's `past_key_values.*` inputs. Stops on
/// the tokenizer's EOS id (`<|im_end|>` for the SmolLM2 chat template).
class SmolLmRunner implements LlmRunner {
  SmolLmRunner({
    ModelBootstrap? bootstrap,
    KvCacheConfig? kvCacheConfig,
    this.maxNewTokens = 1024,
    this.contextWindow = 8192,
    this.idleTtl = const Duration(minutes: 5),
    this.systemPrompt,
  }) : _bootstrap = bootstrap ?? ModelBootstrap(),
       _kv = kvCacheConfig ?? KvCacheConfig.smollm2_360m;

  /// Cap on generated tokens per call. The total prompt + new tokens must
  /// still stay under [contextWindow].
  final int maxNewTokens;

  /// SmolLM2-360M's native context. The tokenizer truncates input that
  /// would not leave room for `maxNewTokens` of output.
  final int contextWindow;

  /// Time the model stays loaded after the last generate call before we
  /// release the ONNX session. 5 min keeps it warm across a typical
  /// background-job cluster while bounding RAM when the app is idle.
  final Duration idleTtl;

  /// Optional system message inserted at the head of every chat prompt.
  /// Generally null — refine and memory prompts already include their
  /// own instructions in the user turn.
  final String? systemPrompt;

  final ModelBootstrap _bootstrap;
  final KvCacheConfig _kv;
  final _onnx = OnnxRuntime();
  final _log = Logger('smollm');

  OrtSession? _session;
  BpeTokenizer? _tokenizer;
  Future<Result<void, LlmError>>? _loading;
  Future<void> _opChain = Future.value();
  Timer? _idleTimer;

  @override
  Future<Result<void, LlmError>> load() {
    return _runExclusive('load', _loadUnlocked);
  }

  Future<Result<void, LlmError>> _loadUnlocked() async {
    _idleTimer?.cancel();
    if (_session != null && _tokenizer != null) return const Ok(null);

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
      final paths = await _bootstrap.ensureSmolLm();
      final tokenizerRes = await BpeTokenizer.load(
        tokenizerJsonPath: paths.tokenizer,
        tokenizerConfigPath: paths.tokenizerConfig,
      );
      switch (tokenizerRes) {
        case Ok(:final value):
          _tokenizer = value;
        case Err(:final error):
          return Err(
            LlmLoadFailed(
              message: 'Failed to load SmolLM2 tokenizer: ${error.message}',
              cause: error.cause,
              stack: error.stack,
            ),
          );
      }

      _log.i('Creating SmolLM2 ONNX session: ${paths.model}');
      final session = await _onnx.createSession(paths.model);
      _session = session;
      _log.i('SmolLM2 session ready');
      return const Ok(null);
    } on Object catch (e, s) {
      return Err(
        LlmLoadFailed(
          message: 'Failed to load SmolLM2: $e',
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
    int topK = 1,
    double topP = 0.95,
    int? randomSeed,
  }) {
    // SmolLM2 was retired before topK/topP/seed plumbing landed. The legacy
    // runner is retained for eval comparison only and ignores the extra
    // sampling knobs.
    return _runExclusive(
      'generate',
      () => _generateUnlocked(prompt, temperature),
    );
  }

  Future<Result<String, LlmError>> _generateUnlocked(
    String prompt,
    double temperature,
  ) async {
    final loaded = await _loadUnlocked();
    switch (loaded) {
      case Ok():
        break;
      case Err(:final error):
        return Err(error);
    }

    final session = _session;
    final tokenizer = _tokenizer;
    if (session == null || tokenizer == null) {
      return const Err(
        LlmRuntimeError(message: 'SmolLM2 session not available after load()'),
      );
    }

    final total = Stopwatch()..start();
    Map<String, OrtValue>? pastKv;

    try {
      final chatPrompt = singleUserPrompt(system: systemPrompt, user: prompt);
      final encodeRes = tokenizer.encodeSegments(chatPrompt.segments);
      final List<int> promptIds;
      switch (encodeRes) {
        case Ok(:final value):
          promptIds = value;
        case Err(:final error):
          return Err(
            LlmRuntimeError(
              message: 'Tokenizer error: ${error.message}',
              cause: error.cause,
              stack: error.stack,
            ),
          );
      }

      final budget = contextWindow - maxNewTokens;
      if (budget <= 0) {
        return const Err(
          LlmRuntimeError(
            message: 'maxNewTokens >= contextWindow leaves no room for prompt',
          ),
        );
      }
      final truncatedPrompt = promptIds.length > budget
          ? promptIds.sublist(promptIds.length - budget)
          : promptIds;
      if (truncatedPrompt.length < promptIds.length) {
        _log.w(
          'Prompt truncated from ${promptIds.length} to '
          '${truncatedPrompt.length} tokens to fit context window '
          '$contextWindow with maxNewTokens=$maxNewTokens',
        );
      }
      _log.i(
        'SmolLM2 generate start: promptTokens=${truncatedPrompt.length} '
        'temperature=$temperature',
      );

      // ---- Prefill --------------------------------------------------------
      final prefillWatch = Stopwatch()..start();
      final prefillIds = Int64List.fromList(truncatedPrompt);
      final prefillMask = Int64List(truncatedPrompt.length)
        ..fillRange(0, truncatedPrompt.length, 1);
      final prefillPos = Int64List.fromList(
        List<int>.generate(truncatedPrompt.length, (i) => i),
      );

      final initialPast = await emptyKvInputs(_kv);
      pastKv = initialPast;
      final prefillInputs = <String, OrtValue>{
        'input_ids': await OrtValue.fromList(prefillIds, [
          1,
          truncatedPrompt.length,
        ]),
        'attention_mask': await OrtValue.fromList(prefillMask, [
          1,
          truncatedPrompt.length,
        ]),
        'position_ids': await OrtValue.fromList(prefillPos, [
          1,
          truncatedPrompt.length,
        ]),
        ...initialPast,
      };

      final prefillOut = await session.run(prefillInputs);
      // The KV inputs are now stale — outputs hold the new state.
      await disposeOrtValues(initialPast);
      // Dispose the non-cache inputs (input_ids, attention_mask, position_ids).
      await prefillInputs['input_ids']?.dispose();
      await prefillInputs['attention_mask']?.dispose();
      await prefillInputs['position_ids']?.dispose();

      pastKv = await rollKvCache(cfg: _kv, stepOutputs: prefillOut);

      final logitsTensor = prefillOut['logits'];
      if (logitsTensor == null) {
        return const Err(
          LlmRuntimeError(message: 'ONNX prefill did not return "logits"'),
        );
      }

      final lastRow = await _lastTokenLogits(
        logitsTensor,
        seqLen: truncatedPrompt.length,
      );
      await logitsTensor.dispose();
      _log.i(
        'SmolLM2 prefill done in ${prefillWatch.elapsedMilliseconds} ms; '
        'vocab=${lastRow.length}',
      );

      final samplerCfg = SamplerConfig(temperature: temperature, topP: 0.9);
      var nextId = sampleToken(
        logits: lastRow,
        vocabSize: lastRow.length,
        config: samplerCfg,
      );
      final eosId = tokenizer.eosTokenId;
      final generated = <int>[];
      if (nextId != eosId) generated.add(nextId);

      // ---- Decode loop ----------------------------------------------------
      final decodeWatch = Stopwatch()..start();
      var produced = generated.length;
      while (produced < maxNewTokens && nextId != eosId) {
        final past = pastKv;
        if (past == null) {
          return const Err(
            LlmRuntimeError(message: 'KV cache lost between decode steps'),
          );
        }
        final totalLen = truncatedPrompt.length + produced;
        final stepInputs = <String, OrtValue>{
          'input_ids': await OrtValue.fromList(Int64List.fromList([nextId]), [
            1,
            1,
          ]),
          'attention_mask': await OrtValue.fromList(
            Int64List(totalLen)..fillRange(0, totalLen, 1),
            [1, totalLen],
          ),
          'position_ids': await OrtValue.fromList(
            Int64List.fromList([totalLen - 1]),
            [1, 1],
          ),
          ...past,
        };

        final stepOut = await session.run(stepInputs);
        await stepInputs['input_ids']?.dispose();
        await stepInputs['attention_mask']?.dispose();
        await stepInputs['position_ids']?.dispose();
        // pastKv values are now superseded by stepOut's `present.*`.
        await disposeOrtValues(pastKv);
        pastKv = await rollKvCache(cfg: _kv, stepOutputs: stepOut);

        final stepLogits = stepOut['logits'];
        if (stepLogits == null) {
          return const Err(
            LlmRuntimeError(message: 'ONNX decode did not return "logits"'),
          );
        }
        final row = await _lastTokenLogits(stepLogits, seqLen: 1);
        await stepLogits.dispose();

        nextId = sampleToken(
          logits: row,
          vocabSize: row.length,
          config: samplerCfg,
        );
        if (nextId == eosId) break;
        generated.add(nextId);
        produced++;

        if (produced % 32 == 0) {
          _log.d(
            'SmolLM2 decode progress: tokens=$produced '
            'elapsed=${decodeWatch.elapsedMilliseconds} ms',
          );
        }
      }
      _log.i(
        'SmolLM2 decode complete: tokens=$produced '
        'in ${decodeWatch.elapsedMilliseconds} ms; '
        'totalGenerate=${total.elapsedMilliseconds} ms',
      );

      final text = tokenizer.decode(generated);
      return Ok(text);
    } on Object catch (e, s) {
      return Err(
        LlmRuntimeError(
          message: 'SmolLM2 generate failed: $e',
          cause: e,
          stack: s,
        ),
      );
    } finally {
      await disposeOrtValues(pastKv);
      _scheduleIdleUnload();
    }
  }

  /// Slice the last-position row out of a `[batch, seq, vocab]` logits
  /// tensor. ONNX returns `List<dynamic>` from `asFlattenedList()`; we
  /// copy the trailing `vocab` floats into a typed `Float32List`.
  Future<Float32List> _lastTokenLogits(
    OrtValue logits, {
    required int seqLen,
  }) async {
    final flat = await logits.asFlattenedList();
    if (flat.isEmpty || seqLen <= 0) {
      throw StateError('Empty logits tensor (seq=$seqLen, len=${flat.length})');
    }
    final vocab = flat.length ~/ seqLen;
    final start = (seqLen - 1) * vocab;
    final out = Float32List(vocab);
    for (var i = 0; i < vocab; i++) {
      out[i] = (flat[start + i] as num).toDouble();
    }
    return out;
  }

  void _scheduleIdleUnload() {
    _idleTimer?.cancel();
    if (idleTtl <= Duration.zero) return;
    _idleTimer = Timer(idleTtl, () async {
      await unload();
    });
  }

  Future<T> _runExclusive<T>(String operation, Future<T> Function() action) {
    final previous = _opChain;
    final done = Completer<void>();
    _opChain = done.future;
    return () async {
      try {
        await previous;
      } on Object {
        // Prior ops convert failures to Result; ignore here.
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
    final session = _session;
    if (session == null) return;
    try {
      await session.close();
      _log.i('SmolLM2 unloaded');
    } on Object catch (e, s) {
      _log.w('SmolLM2 unload failed', error: e, stack: s);
    } finally {
      if (identical(_session, session)) {
        _session = null;
      }
    }
  }

  @override
  Future<void> dispose() async {
    await unload();
    _tokenizer = null;
  }
}
