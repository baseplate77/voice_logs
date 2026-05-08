import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../features/record/parakeet_runner.dart';
import '../features/record/zipformer_streaming_runner.dart';
import 'logger.dart';
import 'native_paths.dart';

/// Paths to e5-small-v2 assets copied to a readable on-device location.
class E5ModelPaths {
  const E5ModelPaths({required this.model, required this.tokenizer});

  /// Path to `model_opt2_QInt8.onnx`.
  final String model;

  /// Path to `tokenizer.json`.
  final String tokenizer;
}

/// Copies ONNX and tokenizer assets out of the APK / IPA into a readable
/// on-disk location so the native sherpa-onnx and flutter_onnxruntime
/// runtimes can mmap them. Idempotent — files are only written when
/// missing or when the bundled checksum changes (see [_maybeCopy]).
class ModelBootstrap {
  ModelBootstrap();

  final _log = Logger('model_bootstrap');

  /// Copy the low-latency streaming Zipformer model. Returns resolved
  /// [ZipformerStreamingModelPaths] pointing at the on-disk copies.
  Future<ZipformerStreamingModelPaths> ensureStreamingZipformer() async {
    final dir = await _modelsDir();
    final zipformer = Directory(p.join(dir.path, 'zipformer_en_20m'));
    if (!zipformer.existsSync()) zipformer.createSync(recursive: true);

    const assets = <String>[
      'assets/models/zipformer_en_20m/encoder-epoch-99-avg-1.int8.onnx',
      'assets/models/zipformer_en_20m/decoder-epoch-99-avg-1.onnx',
      'assets/models/zipformer_en_20m/joiner-epoch-99-avg-1.int8.onnx',
      'assets/models/zipformer_en_20m/tokens.txt',
    ];

    for (final asset in assets) {
      await _maybeCopy(
        asset,
        p.join(dir.path, asset.replaceFirst('assets/models/', '')),
      );
    }

    return ZipformerStreamingModelPaths(
      encoder: p.join(zipformer.path, 'encoder-epoch-99-avg-1.int8.onnx'),
      decoder: p.join(zipformer.path, 'decoder-epoch-99-avg-1.onnx'),
      joiner: p.join(zipformer.path, 'joiner-epoch-99-avg-1.int8.onnx'),
      tokens: p.join(zipformer.path, 'tokens.txt'),
    );
  }

  /// Copy every required file for e5-small-v2 embeddings.
  Future<E5ModelPaths> ensureE5() async {
    final dir = await _modelsDir();
    final e5 = Directory(p.join(dir.path, 'e5'));
    if (!e5.existsSync()) e5.createSync(recursive: true);

    const assets = <String>[
      'assets/models/e5/model_opt2_QInt8.onnx',
      'assets/models/e5/tokenizer.json',
    ];

    for (final asset in assets) {
      await _maybeCopy(
        asset,
        p.join(dir.path, asset.replaceFirst('assets/models/', '')),
      );
    }

    return E5ModelPaths(
      model: p.join(e5.path, 'model_opt2_QInt8.onnx'),
      tokenizer: p.join(e5.path, 'tokenizer.json'),
    );
  }

  /// Copy every required file for the recorder pipeline. Returns the
  /// resolved [ParakeetModelPaths] pointing at the on-disk copies.
  Future<ParakeetModelPaths> ensureParakeet() async {
    final dir = await _modelsDir();
    final parakeet = Directory(p.join(dir.path, 'parakeet'));
    if (!parakeet.existsSync()) parakeet.createSync(recursive: true);

    const assets = <String>[
      'assets/models/parakeet/encoder.int8.onnx',
      'assets/models/parakeet/decoder.int8.onnx',
      'assets/models/parakeet/joiner.int8.onnx',
      'assets/models/parakeet/tokens.txt',
    ];

    for (final asset in assets) {
      await _maybeCopy(
        asset,
        p.join(dir.path, asset.replaceFirst('assets/models/', '')),
      );
    }

    return ParakeetModelPaths(
      encoder: p.join(parakeet.path, 'encoder.int8.onnx'),
      decoder: p.join(parakeet.path, 'decoder.int8.onnx'),
      joiner: p.join(parakeet.path, 'joiner.int8.onnx'),
      tokens: p.join(parakeet.path, 'tokens.txt'),
    );
  }

  Future<Directory> _modelsDir() async {
    final supportPath = await const NativePaths().applicationSupportPath();
    final dir = Directory(p.join(supportPath, 'models'));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  Future<void> _maybeCopy(String assetKey, String destPath) async {
    final file = File(destPath);
    final marker = File('$destPath.size');
    try {
      // Fast path for steady-state launches: if a prior copy wrote a size marker
      // and the destination length still matches, skip loading the asset bytes.
      if (file.existsSync() && marker.existsSync()) {
        final markerSize = int.tryParse((await marker.readAsString()).trim());
        final currentSize = await file.length();
        if (markerSize != null && markerSize == currentSize) {
          return;
        }
      }

      final data = await rootBundle.load(assetKey);
      final bundledLength = data.lengthInBytes;
      if (file.existsSync() && await file.length() == bundledLength) {
        await marker.writeAsString('$bundledLength', flush: true);
        return;
      }
      File(destPath).parent.createSync(recursive: true);
      await file.writeAsBytes(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        flush: true,
      );
      await marker.writeAsString('$bundledLength', flush: true);
      _log.i('Copied $assetKey -> $destPath ($bundledLength bytes)');
    } on Object catch (e, s) {
      _log.w(
        'Asset copy failed for $assetKey; model may be absent in this build',
        error: e,
        stack: s,
      );
    }
  }
}
