import 'dart:typed_data';

import '../core/errors.dart';
import '../core/result.dart';

/// Multilingual text embedder.
///
/// Modelled after `intfloat/multilingual-e5-small`: 384-dim, L2-normalized
/// vectors. E5 expects a `"query: "` or `"passage: "` prefix — the plan
/// (IMPLEMENTATION_PLAN §5 "Gotchas") calls this out as "the #1 mistake"
/// so the interface enforces the distinction with two separate methods
/// rather than letting callers pass raw strings and forget.
abstract class Embedder {
  /// 384 for multilingual-e5-small. Fixed by the model config; we expose
  /// it so downstream (ObjectBox HNSW index) can pin its vector dim.
  int get embeddingDim;

  /// Load the underlying model. Idempotent.
  Future<Result<void, AppError>> load();

  /// Embed a batch of *passages* (things you want to be findable later:
  /// chunk text, document snippets). Adds the `"passage: "` prefix
  /// internally.
  ///
  /// Returned vectors are L2-normalized so cosine similarity is a simple
  /// dot product downstream.
  Future<Result<List<Float32List>, AppError>> embedPassages(List<String> texts);

  /// Embed a single *query*. Adds the `"query: "` prefix internally.
  /// Batched queries are uncommon enough that we offer only the scalar
  /// form; the Phase 5 retriever expands to 2–3 paraphrases and awaits
  /// each concurrently.
  Future<Result<Float32List, AppError>> embedQuery(String text);

  /// Release native handles. Embedder must not be used after.
  Future<void> dispose();
}

/// In-memory scripted embedder for unit tests.
///
/// Deterministic: hashes the (prefix + text) into a seed, fills a fixed
/// `embeddingDim`-length vector from a pseudo-random sequence, then
/// L2-normalizes. Identical inputs → identical vectors; small edits →
/// small perturbations. That's enough to exercise cosine-similarity
/// code paths in Phase 5 retrieval tests without real model weights.
class FakeEmbedder implements Embedder {
  FakeEmbedder({this.embeddingDim = 384});

  @override
  final int embeddingDim;

  bool _loaded = false;
  bool _disposed = false;
  int _callCount = 0;

  /// Number of embed calls seen — test assertions can check it.
  int get callCount => _callCount;

  @override
  Future<Result<void, AppError>> load() async {
    if (_disposed) {
      return const Err<void, AppError>(
        UnknownError('FakeEmbedder already disposed'),
      );
    }
    _loaded = true;
    return const Ok<void, AppError>(null);
  }

  @override
  Future<Result<List<Float32List>, AppError>> embedPassages(
    List<String> texts,
  ) async {
    final err = _preflight();
    if (err != null) {
      return Err<List<Float32List>, AppError>(err);
    }
    _callCount++;
    final out = <Float32List>[];
    for (final t in texts) {
      out.add(_deterministic('passage: $t'));
    }
    return Ok<List<Float32List>, AppError>(out);
  }

  @override
  Future<Result<Float32List, AppError>> embedQuery(String text) async {
    final err = _preflight();
    if (err != null) {
      return Err<Float32List, AppError>(err);
    }
    _callCount++;
    return Ok<Float32List, AppError>(_deterministic('query: $text'));
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    _loaded = false;
  }

  AppError? _preflight() {
    if (_disposed) {
      return const UnknownError('FakeEmbedder already disposed');
    }
    if (!_loaded) {
      return const ModelLoadError('<fake>', reason: 'embed called before load');
    }
    return null;
  }

  /// Produce an L2-unit vector that depends deterministically on [key].
  /// FNV-1a gives a cheap, well-distributed seed; the mulberry32 PRNG
  /// gives us stable floats without depending on `dart:math.Random`
  /// (which can be seeded but is slightly less predictable across
  /// platforms).
  Float32List _deterministic(String key) {
    var h = 0x811c9dc5;
    for (var i = 0; i < key.length; i++) {
      h ^= key.codeUnitAt(i);
      h = (h * 0x01000193) & 0xFFFFFFFF;
    }
    var state = h == 0 ? 1 : h;

    final out = Float32List(embeddingDim);
    var sumSq = 0.0;
    for (var i = 0; i < embeddingDim; i++) {
      state = (state + 0x6D2B79F5) & 0xFFFFFFFF;
      var t = state;
      t = ((t ^ (t >> 15)) * (t | 1)) & 0xFFFFFFFF;
      t ^= t + (((t ^ (t >> 7)) * (t | 61)) & 0xFFFFFFFF);
      final u = ((t ^ (t >> 14)) & 0xFFFFFFFF) / 0xFFFFFFFF;
      final v = u * 2.0 - 1.0; // [-1, 1]
      out[i] = v;
      sumSq += v * v;
    }
    final norm = sumSq == 0.0 ? 1.0 : sumSq;
    // sqrt once, then divide.
    final invNorm = 1.0 / _sqrt(norm);
    for (var i = 0; i < embeddingDim; i++) {
      out[i] = out[i] * invNorm;
    }
    return out;
  }

  // Avoid importing dart:math just for sqrt in this helper.
  static double _sqrt(double x) {
    if (x <= 0.0) return 0.0;
    var guess = x;
    for (var i = 0; i < 20; i++) {
      guess = 0.5 * (guess + x / guess);
    }
    return guess;
  }
}

/// Cosine similarity between two vectors. Assumes both are L2-normalized
/// (as both FakeEmbedder and E5Embedder return). Downstream code in
/// Phase 5 uses this for score aggregation.
double cosineSimilarity(Float32List a, Float32List b) {
  assert(a.length == b.length, 'vectors must have equal length');
  var dot = 0.0;
  for (var i = 0; i < a.length; i++) {
    dot += a[i] * b[i];
  }
  return dot;
}
