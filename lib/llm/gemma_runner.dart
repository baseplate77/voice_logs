// coverage:ignore-file
//
// Production [LlmRunner] backed by `flutter_gemma` (MediaPipe / LiteRT-LM).
// The `.litertlm` bundle ships inside the Flutter asset tree (see
// `pubspec.yaml` and `.gitignore` — the file itself is developer-local,
// not checked into git). On first launch flutter_gemma's
// AssetSourceHandler copies it out of the APK into the plugin's own
// cache; subsequent launches are ~instant.
//
// Default model is `litert-community/gemma-4-E2B-it.litertlm` (~2.58 GB
// on disk, ~676 MB resident on GPU).

import 'package:flutter_gemma/flutter_gemma.dart';

import '../core/errors.dart';
import '../core/result.dart';
import 'llm_runner.dart';

/// Progress callback fired while flutter_gemma is copying the
/// `.litertlm` bundle out of the APK asset tree. [percent] is 0..100.
typedef GemmaInstallProgress = void Function(int percent);

/// Default source for the Gemma 4 E2B instruction-tuned `.litertlm`
/// bundle. Relative to the Flutter asset root (`pubspec.yaml` lists the
/// exact file so a missing drop-in trips a loud build error).
const String kDefaultGemmaAssetPath =
    'assets/models/gemma/gemma-4-E2B-it.litertlm';

/// Model family the default asset is from. Swap both together if you
/// drop in a Qwen / DeepSeek / Phi / SmolLM checkpoint.
const ModelType kDefaultGemmaModelType = ModelType.gemmaIt;

/// flutter_gemma treats `.task` and `.litertlm` identically on the
/// mobile path, but the enum distinguishes them — match what's on disk.
const ModelFileType kDefaultGemmaModelFileType = ModelFileType.litertlm;

class GemmaRunner implements LlmRunner {
  GemmaRunner({
    this.assetPath = kDefaultGemmaAssetPath,
    this.modelType = kDefaultGemmaModelType,
    this.fileType = kDefaultGemmaModelFileType,
    this.onInstallProgress,
    this.preferredBackend = PreferredBackend.gpu,
  });

  /// Flutter asset path to the `.task` or `.litertlm` file. Defaults to
  /// the Gemma 4 E2B bundle; any flutter_gemma-compatible checkpoint can
  /// be swapped in by changing this + [modelType] together.
  final String assetPath;

  /// Must match [assetPath]'s family (e.g. [ModelType.gemmaIt] for
  /// Gemma, [ModelType.qwen] for Qwen). Controls how flutter_gemma
  /// applies chat templates.
  final ModelType modelType;

  /// `.task` for MediaPipe, `.litertlm` for LiteRT-LM (same runtime
  /// path on mobile). Must match what's at [assetPath].
  final ModelFileType fileType;

  /// Fired while the asset is being copied out of the APK on first run.
  /// Safe to leave null.
  final GemmaInstallProgress? onInstallProgress;

  /// Gemma 4 E2B's memory-mapped embeddings make GPU the right default:
  /// ~676 MB on GPU vs ~1.7 GB on CPU on a Snapdragon-class SoC. Fall
  /// back to [PreferredBackend.cpu] if a device lacks a usable GPU
  /// backend.
  final PreferredBackend preferredBackend;

  InferenceModel? _model;
  double _temperature = 0.3;
  // 2048 — the hard-baked max_num_tokens of
  // `litert-community/gemma-4-E2B-it-litert-lm`. Asking for more
  // fails at load with `Failed to create engine: INTERNAL: ERROR`.
  // Long transcripts need to be trimmed / chunked by callers rather
  // than worked around here.
  int _maxTokens = 2048;

  /// The plugin's `ServiceRegistry.initialize()` is idempotent past the
  /// first `_instance != null` short-circuit. We still guard locally so
  /// repeated `load()` calls don't re-await it.
  static bool _pluginInitialized = false;

  /// Copy the asset out of the APK into flutter_gemma's cache without
  /// spinning up an [InferenceModel]. Intended for app bootstrap: the
  /// 2.58 GB copy is paid once up-front rather than mid-cleanup, but no
  /// runtime RAM is committed until [load] is called later. Idempotent:
  /// a subsequent [load] will short-circuit the already-installed file.
  static Future<Result<void, AppError>> warmUp({
    String assetPath = kDefaultGemmaAssetPath,
    ModelType modelType = kDefaultGemmaModelType,
    ModelFileType fileType = kDefaultGemmaModelFileType,
    GemmaInstallProgress? onInstallProgress,
  }) async {
    try {
      if (!_pluginInitialized) {
        await FlutterGemma.initialize();
        _pluginInitialized = true;
      }

      final builder = FlutterGemma.installModel(
        modelType: modelType,
        fileType: fileType,
      ).fromAsset(assetPath);

      final withProgress = onInstallProgress == null
          ? builder
          : builder.withProgress((progress) {
              final clamped = progress < 0
                  ? 0
                  : progress > 100
                      ? 100
                      : progress;
              onInstallProgress(clamped);
            });

      await withProgress.install();
      return const Ok<void, AppError>(null);
    } on Object catch (e, st) {
      return Err<void, AppError>(
        ModelLoadError(
          assetPath,
          reason: 'flutter_gemma warmUp failed: $e',
          cause: e,
          stackTrace: st,
        ),
      );
    }
  }

  @override
  Future<Result<void, AppError>> load({
    int maxTokens = 2048,
    double temperature = 0.3,
  }) async {
    _temperature = temperature;
    _maxTokens = maxTokens;
    try {
      if (!_pluginInitialized) {
        await FlutterGemma.initialize();
        _pluginInitialized = true;
      }

      final builder = FlutterGemma.installModel(
        modelType: modelType,
        fileType: fileType,
      ).fromAsset(assetPath);

      final withProgress = onInstallProgress == null
          ? builder
          : builder.withProgress((progress) {
              final clamped = progress < 0
                  ? 0
                  : progress > 100
                      ? 100
                      : progress;
              onInstallProgress!(clamped);
            });

      // install() is idempotent — the plugin short-circuits if the same
      // asset is already cached on device. First launch pays the copy
      // cost (~2.58 GB for Gemma 4 E2B); subsequent launches are
      // ~O(seconds).
      await withProgress.install();

      _model = await FlutterGemma.getActiveModel(
        maxTokens: _maxTokens,
        preferredBackend: preferredBackend,
      );
      return const Ok<void, AppError>(null);
    } on Object catch (e, st) {
      return Err<void, AppError>(
        ModelLoadError(
          assetPath,
          reason: 'flutter_gemma install/load failed: $e',
          cause: e,
          stackTrace: st,
        ),
      );
    }
  }

  @override
  Stream<String> generate(
    String prompt, {
    double? temperatureOverride,
  }) async* {
    final model = _model;
    if (model == null) {
      throw StateError('GemmaRunner.generate called before load');
    }
    InferenceModelSession? session;
    try {
      session = await model.createSession(
        temperature: temperatureOverride ?? _temperature,
      );
      await session.addQueryChunk(Message.text(text: prompt, isUser: true));
      yield* session.getResponseAsync();
    } finally {
      // Session close is best-effort — leaking the native handle is
      // preferable to throwing over a working generation.
      try {
        await session?.close();
      } on Object catch (_) {}
    }
  }

  @override
  Future<Result<String, AppError>> generateSync(
    String prompt, {
    double? temperatureOverride,
  }) async {
    final model = _model;
    if (model == null) {
      return Err<String, AppError>(
        ModelLoadError(assetPath, reason: 'generateSync called before load'),
      );
    }
    InferenceModelSession? session;
    try {
      session = await model.createSession(
        temperature: temperatureOverride ?? _temperature,
      );
      await session.addQueryChunk(Message.text(text: prompt, isUser: true));
      final response = await session.getResponse();
      return Ok<String, AppError>(response);
    } on Object catch (e, st) {
      return Err<String, AppError>(
        UnknownError(
          'Gemma generateSync failed: $e',
          cause: e,
          stackTrace: st,
        ),
      );
    } finally {
      try {
        await session?.close();
      } on Object catch (_) {}
    }
  }

  @override
  Future<void> dispose() async {
    final model = _model;
    _model = null;
    if (model != null) {
      try {
        await model.close();
      } on Object catch (_) {}
    }
  }
}
