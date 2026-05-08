import 'package:flutter/services.dart';

/// Thin MethodChannel wrapper that returns the same directory paths as
/// `path_provider` would, but through a channel registered in
/// [MainActivity.configureFlutterEngine]. We bypass `path_provider` on
/// Android because the path_provider_android pigeon channel was failing
/// with `channel-error` on cold boot (Pixel 6a, 2026-04-22), independent
/// of timing or the 2.3.x jni issue.
class NativePaths {
  const NativePaths();

  static const _channel = MethodChannel('com.nj.voxsynth/paths');

  /// Absolute path to the app's private files directory — equivalent to
  /// Android `context.filesDir`. Used as the storage root for the DB and
  /// recorded audio.
  Future<String> applicationDocumentsPath() =>
      _invoke('getApplicationDocumentsPath');

  /// Absolute path to the app's private support directory. On Android
  /// this resolves to the same location as the documents path.
  Future<String> applicationSupportPath() =>
      _invoke('getApplicationSupportPath');

  /// Absolute path to a cache-scoped directory (`context.cacheDir` on
  /// Android).
  Future<String> temporaryPath() => _invoke('getTemporaryPath');

  Future<String> _invoke(String method) async {
    final path = await _channel.invokeMethod<String>(method);
    if (path == null || path.isEmpty) {
      throw StateError('NativePaths.$method returned null/empty');
    }
    return path;
  }
}
