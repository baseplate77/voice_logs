import 'dart:io';
import 'dart:isolate';

import 'package:flutter/services.dart'
    show BackgroundIsolateBinaryMessenger, RootIsolateToken, rootBundle;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Filesystem paths to every model the debug UI needs, once they've been
/// materialised out of the APK/IPA asset bundle and onto disk.
///
/// The Rust-backed runners (Parakeet, E5, Gemma) only accept real
/// filesystem paths — they cannot read Flutter's `asset://` URIs. On
/// Android the asset bundle is a zip inside the APK, so on first launch
/// we copy every model file into the app's documents directory.
class ModelPaths {
  const ModelPaths({
    required this.parakeetDir,
    required this.e5Weights,
    required this.e5Config,
    required this.e5Tokenizer,
  });

  final String parakeetDir;
  final String e5Weights;
  final String e5Config;
  final String e5Tokenizer;

  // Gemma is not tracked here: flutter_gemma caches its bundle inside
  // the plugin's own storage, not under app documents. The download
  // itself is now driven at startup by `gemmaWarmUpProvider`
  // (see lib/ui/debug/debug_providers.dart) — completion of that
  // provider is what flips `coreRuntimeProvider` to ready.
}

/// Progress callback fired as each bundled model is copied out of the APK.
/// [fileIndex] / [totalFiles] is file-count progress; [currentFile] is the
/// relative path under `assets/models/`.
typedef BootstrapProgress = void Function(
  String currentFile,
  int fileIndex,
  int totalFiles,
);

const _assetFiles = <String>[
  'assets/models/parakeet/encoder.int8.onnx',
  'assets/models/parakeet/decoder.int8.onnx',
  'assets/models/parakeet/joiner.int8.onnx',
  'assets/models/parakeet/tokens.txt',
  'assets/models/e5/model.safetensors',
  'assets/models/e5/config.json',
  'assets/models/e5/tokenizer.json',
];

/// Copy every bundled model into `{app-documents}/models/...` if it isn't
/// already there, and return the absolute paths so services can load them.
///
/// **Runs on a background isolate.** The e5 weights alone are ~450 MB;
/// loading it into Dart memory as ByteData plus the subsequent disk
/// write easily stalls the UI isolate for 10+ seconds. Pushing this off
/// the root isolate keeps animations smooth during first-launch.
///
/// Idempotent: a file whose on-disk length matches the bundled asset's
/// length is assumed up-to-date and skipped.
Future<ModelPaths> bootstrapModels({BootstrapProgress? onProgress}) async {
  final token = RootIsolateToken.instance;
  if (token == null) {
    // Running in a context without the platform binding — falls back
    // to the in-isolate path. Only hit by some test harnesses; the
    // production Flutter app always has a non-null token.
    return _bootstrap(onProgress);
  }

  final progressPort = ReceivePort();
  progressPort.listen((Object? msg) {
    if (msg is List<Object?> && msg.length == 3) {
      onProgress?.call(
        msg[0] as String,
        msg[1] as int,
        msg[2] as int,
      );
    }
  });

  try {
    return await _spawnBootstrapIsolate(token, progressPort.sendPort);
  } on Object catch (e, st) {
    // Background-isolate bootstrap can fail on some Flutter/Dart
    // combinations (RootIsolateToken not yet propagated, missing
    // binary-messenger init, …). Fall back to an in-isolate copy so
    // the user can still proceed — the cost is a UI stall during the
    // Gemma file write, which is still better than a hard failure.
    // ignore: avoid_print
    print('[bootstrap] isolate path failed: $e\n$st\nfalling back');
    return _bootstrap(onProgress);
  } finally {
    progressPort.close();
  }
}

/// Spawns the bootstrap isolate in its own function so the closure
/// captures *only* [token] and [sendPort]. Dart shares one context
/// object across all nested closures of a function, so defining the
/// `Isolate.run` call alongside the `progressPort.listen` callback
/// would pull `onProgress` (and its Riverpod `ref`) into the sent
/// closure and trigger "object is unsendable".
Future<ModelPaths> _spawnBootstrapIsolate(
  RootIsolateToken token,
  SendPort sendPort,
) {
  return Isolate.run<ModelPaths>(
    () => _bootstrapEntry(token, sendPort),
  );
}

/// Top-level isolate entry-point. Flutter's background-isolate messenger
/// must be initialised before any platform channels (including
/// `rootBundle` and `path_provider`) are used off the root isolate.
Future<ModelPaths> _bootstrapEntry(
  RootIsolateToken token,
  SendPort progressPort,
) async {
  BackgroundIsolateBinaryMessenger.ensureInitialized(token);
  return _bootstrap((file, i, total) {
    progressPort.send(<Object>[file, i, total]);
  });
}

Future<ModelPaths> _bootstrap(BootstrapProgress? onProgress) async {
  final docs = await getApplicationDocumentsDirectory();
  final modelsRoot = Directory(p.join(docs.path, 'models'));
  if (!modelsRoot.existsSync()) {
    modelsRoot.createSync(recursive: true);
  }

  for (var i = 0; i < _assetFiles.length; i++) {
    final assetKey = _assetFiles[i];
    final relativePath = assetKey.replaceFirst('assets/models/', '');
    final destFile = File(p.join(modelsRoot.path, relativePath));

    onProgress?.call(relativePath, i, _assetFiles.length);

    final assetData = await rootBundle.load(assetKey);
    final assetBytes = assetData.buffer
        .asUint8List(assetData.offsetInBytes, assetData.lengthInBytes);

    if (!destFile.existsSync() ||
        destFile.lengthSync() != assetBytes.length) {
      destFile.parent.createSync(recursive: true);
      await destFile.writeAsBytes(assetBytes, flush: true);
    }
  }
  onProgress?.call('done', _assetFiles.length, _assetFiles.length);

  return ModelPaths(
    parakeetDir: p.join(modelsRoot.path, 'parakeet'),
    e5Weights: p.join(modelsRoot.path, 'e5', 'model.safetensors'),
    e5Config: p.join(modelsRoot.path, 'e5', 'config.json'),
    e5Tokenizer: p.join(modelsRoot.path, 'e5', 'tokenizer.json'),
  );
}
