import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';

import '../../core/app_error.dart';
import '../../core/model_bootstrap.dart';
import '../../core/result.dart';
import 'embedding_math.dart';
import 'tokenizer.dart';

/// Embedding dimension of e5-small-v2.
const int kEmbeddingDim = 384;

/// Max sequence length the model was trained on.
const int kMaxSeqLen = 512;

/// One embedding vector paired with the text that produced it. Stored
/// L2-normalized so cosine similarity reduces to a dot product in
/// sqlite-vec / our in-memory store.
class Embedding {
  const Embedding({required this.vector, required this.dim});

  /// L2-normalized vector of length [dim].
  final Float32List vector;
  final int dim;
}

/// Errors produced while embedding text.
sealed class EmbedError extends AppError {
  const EmbedError({required super.message, super.cause, super.stack});
}

final class EmbedModelMissing extends EmbedError {
  const EmbedModelMissing(String path)
    : super(message: 'E5 model file not found: $path');
}

final class EmbedLoadFailed extends EmbedError {
  const EmbedLoadFailed({required super.message, super.cause, super.stack});
}

final class EmbedRuntimeError extends EmbedError {
  const EmbedRuntimeError({required super.message, super.cause, super.stack});
}

/// Abstract embedder. Tests use a canned implementation; production
/// binds to [E5Embedder].
abstract class Embedder {
  Future<Result<void, EmbedError>> load();

  /// Embed one or more indexed passages. Applies the `"passage: "`
  /// prefix automatically — do not pre-prefix the input.
  Future<Result<List<Embedding>, EmbedError>> embedPassages(
    List<String> texts, {
    int? batchSize,
  });

  /// Embed a single search query. Applies the `"query: "` prefix.
  Future<Result<Embedding, EmbedError>> embedQuery(String text);

  Future<void> dispose();
}

/// Lazily copies e5 assets, loads the tokenizer, then delegates to
/// [E5Embedder]. This lets providers stay synchronous while model IO
/// remains deferred to the background worker/search path.
class LazyE5Embedder implements Embedder {
  LazyE5Embedder({required this.bootstrap});

  final ModelBootstrap bootstrap;
  E5Embedder? _delegate;
  Future<Result<void, EmbedError>>? _loading;

  @override
  Future<Result<void, EmbedError>> load() {
    final existing = _loading;
    if (existing != null) return existing;
    final loading = _loadOnce().then((result) {
      if (result is Err<void, EmbedError>) _loading = null;
      return result;
    });
    _loading = loading;
    return loading;
  }

  Future<Result<void, EmbedError>> _loadOnce() async {
    final existing = _delegate;
    if (existing != null) return const Ok(null);
    try {
      final paths = await bootstrap.ensureE5();
      final tokenizerRes = await BertWordPieceTokenizer.load(paths.tokenizer);
      final BertWordPieceTokenizer tokenizer;
      switch (tokenizerRes) {
        case Ok(:final value):
          tokenizer = value;
        case Err(:final error):
          return Err(
            EmbedLoadFailed(
              message: 'Failed to load e5 tokenizer: ${error.message}',
              cause: error.cause,
              stack: error.stack,
            ),
          );
      }
      final delegate = E5Embedder(modelPath: paths.model, tokenizer: tokenizer);
      final loaded = await delegate.load();
      switch (loaded) {
        case Ok():
          _delegate = delegate;
          return const Ok(null);
        case Err(:final error):
          await delegate.dispose();
          return Err(error);
      }
    } on Object catch (e, s) {
      _loading = null;
      return Err(
        EmbedLoadFailed(
          message: 'Failed to initialize e5 embedder: $e',
          cause: e,
          stack: s,
        ),
      );
    }
  }

  @override
  Future<Result<List<Embedding>, EmbedError>> embedPassages(
    List<String> texts, {
    int? batchSize,
  }) async {
    final loaded = await load();
    switch (loaded) {
      case Ok():
        return _delegate!.embedPassages(texts, batchSize: batchSize);
      case Err(:final error):
        return Err(error);
    }
  }

  @override
  Future<Result<Embedding, EmbedError>> embedQuery(String text) async {
    final loaded = await load();
    switch (loaded) {
      case Ok():
        return _delegate!.embedQuery(text);
      case Err(:final error):
        return Err(error);
    }
  }

  @override
  Future<void> dispose() async {
    await _delegate?.dispose();
    _delegate = null;
    _loading = null;
  }
}

/// `flutter_onnxruntime`-backed e5-small-v2 embedder.
///
/// Phase 3 keeps the runner single-threaded and on the main isolate for
/// simplicity; Phase 4+ moves it onto a dedicated worker isolate
/// alongside Gemma behind the same [Embedder] interface.
class E5Embedder implements Embedder {
  E5Embedder({
    required this.modelPath,
    required this.tokenizer,
    this.maxBatchSize = 8,
  });

  /// On-disk path to `model_opt2_QInt8.onnx`.
  final String modelPath;
  final Tokenizer tokenizer;
  final int maxBatchSize;

  OrtSession? _session;
  final _onnx = OnnxRuntime();

  @override
  Future<Result<void, EmbedError>> load() async {
    if (_session != null) return const Ok(null);
    try {
      final session = await _onnx.createSession(modelPath);
      _session = session;
      return const Ok(null);
    } on Object catch (e, s) {
      return Err(
        EmbedLoadFailed(
          message: 'Failed to load e5 model: $e',
          cause: e,
          stack: s,
        ),
      );
    }
  }

  @override
  Future<Result<List<Embedding>, EmbedError>> embedPassages(
    List<String> texts, {
    int? batchSize,
  }) async {
    if (texts.isEmpty) return const Ok([]);
    final cappedBatch = math.max(1, batchSize ?? maxBatchSize);
    final all = <Embedding>[];
    for (var i = 0; i < texts.length; i += cappedBatch) {
      final end = math.min(i + cappedBatch, texts.length);
      final chunk = texts
          .sublist(i, end)
          .map((t) => 'passage: $t')
          .toList(growable: false);
      final embedded = await _embedBatch(chunk);
      switch (embedded) {
        case Ok(:final value):
          all.addAll(value);
        case Err(:final error):
          return Err(error);
      }
    }
    return Ok(all);
  }

  @override
  Future<Result<Embedding, EmbedError>> embedQuery(String text) async {
    final res = await _embedBatch(['query: $text']);
    return switch (res) {
      Ok(:final value) => Ok(value.first),
      Err(:final error) => Err(error),
    };
  }

  Future<Result<List<Embedding>, EmbedError>> _embedBatch(
    List<String> prefixed,
  ) async {
    final session = _session;
    if (session == null) {
      return const Err(
        EmbedRuntimeError(message: 'E5Embedder.load() not called'),
      );
    }
    try {
      final tokenized = prefixed.map(tokenizer.encode).toList();
      final batch = tokenized.length;
      const seq = kMaxSeqLen;

      final inputIds = Int64List(batch * seq);
      final attention = Int64List(batch * seq);
      for (var b = 0; b < batch; b++) {
        for (var s = 0; s < seq; s++) {
          inputIds[b * seq + s] = tokenized[b].inputIds[s];
          attention[b * seq + s] = tokenized[b].attentionMask[s];
        }
      }

      final inputs = <String, OrtValue>{
        'input_ids': await OrtValue.fromList(inputIds, [batch, seq]),
        'attention_mask': await OrtValue.fromList(attention, [batch, seq]),
        'token_type_ids': await OrtValue.fromList(Int64List(batch * seq), <int>[
          batch,
          seq,
        ]),
      };

      final outputs = await session.run(inputs);
      final last = outputs['last_hidden_state'];
      if (last == null) {
        return const Err(
          EmbedRuntimeError(message: 'ONNX did not return last_hidden_state'),
        );
      }
      final raw = await last.asFlattenedList();
      final values = Float32List(raw.length);
      for (var i = 0; i < raw.length; i++) {
        values[i] = (raw[i] as num).toDouble();
      }

      // Recast attention mask to float for pooling math.
      final attentionF = Float32List(attention.length);
      for (var i = 0; i < attention.length; i++) {
        attentionF[i] = attention[i].toDouble();
      }

      final pooled = meanPool(
        lastHiddenState: values,
        attentionMask: attentionF,
        batch: batch,
        seq: seq,
        hidden: kEmbeddingDim,
      );
      l2Normalize(values: pooled, batch: batch, hidden: kEmbeddingDim);

      final embeddings = <Embedding>[];
      for (var b = 0; b < batch; b++) {
        final vec = Float32List(kEmbeddingDim);
        for (var h = 0; h < kEmbeddingDim; h++) {
          vec[h] = pooled[b * kEmbeddingDim + h];
        }
        embeddings.add(Embedding(vector: vec, dim: kEmbeddingDim));
      }
      return Ok(embeddings);
    } on Object catch (e, s) {
      return Err(
        EmbedRuntimeError(message: 'Embedding failed: $e', cause: e, stack: s),
      );
    }
  }

  @override
  Future<void> dispose() async {
    await _session?.close();
    _session = null;
  }
}
