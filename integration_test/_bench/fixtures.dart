import 'dart:io';

import 'package:flutter/services.dart';

/// Extracts an asset from the rootBundle to a writable file path.
/// Idempotent — does not re-write if the file is already there with
/// the same byte length as the asset.
Future<String> extractAsset(String assetKey, String destPath) async {
  final file = File(destPath);
  final data = await rootBundle.load(assetKey);
  final size = data.lengthInBytes;
  if (file.existsSync() && await file.length() == size) {
    return destPath;
  }
  file.parent.createSync(recursive: true);
  await file.writeAsBytes(
    data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
    flush: true,
  );
  return destPath;
}
