import 'dart:io';

import 'package:flutter/services.dart';

import 'logger.dart';

/// Configures the native AVAudioSession for background recording on iOS.
/// No-op on non-iOS platforms.
class AudioSessionBridge {
  AudioSessionBridge._();

  static const _channel = MethodChannel('com.nj.voxsynth/audio');
  static final _log = Logger('audio_session');
  static bool _configured = false;

  /// Ensures the audio session is configured for recording.
  /// Safe to call multiple times — only configures once.
  static Future<void> ensureConfigured() async {
    if (_configured || !Platform.isIOS) return;
    try {
      await _channel.invokeMethod<bool>('configureAudioSession');
      _configured = true;
    } on PlatformException catch (e) {
      _log.w('Audio session configuration failed: ${e.message}');
    }
  }
}
