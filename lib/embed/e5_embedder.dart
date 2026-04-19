// coverage:ignore-file
//
// E5Embedder is the production [Embedder]. Delegates to candle's
// xlm_roberta inside voxsynth_asr, so exercising it requires the Rust
// dylib built and model files on disk. Covered end-to-end by
// test/embed/e5_embedder_integration_test.dart; unit tests stick to
// FakeEmbedder.

import 'dart:typed_data';

import '../core/errors.dart';
import '../core/result.dart';
import '../src/rust/api/embed.dart' as rust;
import '../src/rust/frb_generated.dart' as frb;
import 'embedder.dart';

/// Production [Embedder] backed by multilingual-e5-small running through
/// the Rust crate.
///
/// The E5 `"query: "` / `"passage: "` convention is enforced here, not
/// in the Rust layer — so swapping to a different embedding model later
/// (one that doesn't need prefixes) is a one-file change.
class E5Embedder implements Embedder {
  E5Embedder({
    required this.weightsPath,
    required this.configPath,
    required this.tokenizerPath,
  });

  /// Absolute path to `model.safetensors`.
  final String weightsPath;

  /// Absolute path to `config.json`.
  final String configPath;

  /// Absolute path to `tokenizer.json`.
  final String tokenizerPath;

  @override
  int get embeddingDim => 384;

  bool _loaded = false;
  bool _disposed = false;

  @override
  Future<Result<void, AppError>> load() async {
    if (_disposed) {
      return const Err<void, AppError>(
        ModelLoadError('e5', reason: 'embedder already disposed'),
      );
    }
    try {
      if (!frb.RustLib.instance.initialized) {
        await frb.RustLib.init();
      }
      await rust.loadE5(
        weightsPath: weightsPath,
        configPath: configPath,
        tokenizerPath: tokenizerPath,
      );
      _loaded = true;
      return const Ok<void, AppError>(null);
    } on Object catch (e, st) {
      return Err<void, AppError>(
        ModelLoadError(
          weightsPath,
          reason: 'Rust loadE5 failed',
          cause: e,
          stackTrace: st,
        ),
      );
    }
  }

  @override
  Future<Result<List<Float32List>, AppError>> embedPassages(
    List<String> texts,
  ) async {
    final err = _preflight();
    if (err != null) return Err<List<Float32List>, AppError>(err);
    final prefixed = texts.map((t) => 'passage: $t').toList(growable: false);
    return _embedRaw(prefixed);
  }

  @override
  Future<Result<Float32List, AppError>> embedQuery(String text) async {
    final err = _preflight();
    if (err != null) return Err<Float32List, AppError>(err);
    final result = await _embedRaw(<String>['query: $text']);
    return result.map((vs) => vs.single);
  }

  Future<Result<List<Float32List>, AppError>> _embedRaw(
    List<String> prefixed,
  ) async {
    try {
      final vectors = await rust.embedBatch(texts: prefixed);
      final out = vectors.map(Float32List.fromList).toList(growable: false);
      return Ok<List<Float32List>, AppError>(out);
    } on Object catch (e, st) {
      return Err<List<Float32List>, AppError>(
        UnknownError(
          'e5 embed_batch failed',
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
      await rust.disposeEmbedder();
    } on Object catch (_) {
      // best-effort
    }
  }

  AppError? _preflight() {
    if (_disposed) {
      return const UnknownError('E5Embedder already disposed');
    }
    if (!_loaded) {
      return const ModelLoadError('e5', reason: 'embed called before load');
    }
    return null;
  }
}
