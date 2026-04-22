import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../features/record/parakeet_runner.dart';
import 'logger.dart';

/// Copies ONNX and tokenizer assets out of the APK / IPA into a readable
/// on-disk location so the native sherpa-onnx and flutter_onnxruntime
/// runtimes can mmap them. Idempotent — files are only written when
/// missing or when the bundled checksum changes (see [_maybeCopy]).
class ModelBootstrap {
  ModelBootstrap();

  final _log = Logger('model_bootstrap');

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
        p.join(dir.path, asset.replaceFirst('assets/', '')),
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
    final support = await getApplicationSupportDirectory();
    final dir = Directory(p.join(support.path, 'models'));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  Future<void> _maybeCopy(String assetKey, String destPath) async {
    final file = File(destPath);
    try {
      final data = await rootBundle.load(assetKey);
      final bundledLength = data.lengthInBytes;
      if (file.existsSync() && await file.length() == bundledLength) {
        return;
      }
      File(destPath).parent.createSync(recursive: true);
      await file.writeAsBytes(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        flush: true,
      );
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
