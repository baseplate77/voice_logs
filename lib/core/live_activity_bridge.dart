import 'dart:io';

import 'package:flutter/services.dart';

import 'logger.dart';

/// Manages iOS Live Activity / Dynamic Island for recording state.
/// No-op on non-iOS platforms.
class LiveActivityBridge {
  LiveActivityBridge._();

  static const _channel = MethodChannel('com.nj.voxsynth/live_activity');
  static final _log = Logger('live_activity');

  static Future<bool> startActivity({
    int elapsedSeconds = 0,
    required DateTime startedAt,
    List<double> waveformLevels = const [],
  }) async {
    if (!Platform.isIOS) return false;
    try {
      return await _channel.invokeMethod<bool>('startActivity', {
            'elapsedSeconds': elapsedSeconds,
            'startedAtMillis': startedAt.millisecondsSinceEpoch,
            'waveformLevels': waveformLevels,
          }) ??
          false;
    } on PlatformException catch (e) {
      _log.w('Failed to start Live Activity: ${e.message}');
      return false;
    }
  }

  static Future<void> updateActivity({
    required int elapsedSeconds,
    required DateTime? startedAt,
    bool isTranscribing = false,
    List<double> waveformLevels = const [],
  }) async {
    if (!Platform.isIOS) return;
    try {
      await _channel.invokeMethod<bool>('updateActivity', {
        'elapsedSeconds': elapsedSeconds,
        'startedAtMillis': startedAt?.millisecondsSinceEpoch ?? 0,
        'isTranscribing': isTranscribing,
        'waveformLevels': waveformLevels,
      });
    } on PlatformException catch (e) {
      _log.w('Failed to update Live Activity: ${e.message}');
    }
  }

  static Future<void> endActivity() async {
    if (!Platform.isIOS) return;
    try {
      await _channel.invokeMethod<bool>('endActivity');
    } on PlatformException catch (e) {
      _log.w('Failed to end Live Activity: ${e.message}');
    }
  }
}
