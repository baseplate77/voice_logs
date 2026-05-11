import 'dart:async';

import 'package:flutter/services.dart';

import 'logger.dart';

/// Listens for intent actions dispatched from iOS App Intents and URL scheme
/// handlers. Emits action strings ('start', 'stop') that the app layer
/// routes to the recording controller.
class IntentBridge {
  IntentBridge._();

  static const _channel = MethodChannel('com.nj.voxsynth/intents');
  static final _log = Logger('intent_bridge');
  static final _controller = StreamController<String>.broadcast();

  /// Stream of intent action strings ('start', 'stop').
  static Stream<String> get actions => _controller.stream;

  /// Call once at app startup to begin listening for intent actions and
  /// flush any pending action queued before the Flutter engine was ready.
  static void initialize() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onIntentAction') {
        final action = call.arguments as String?;
        if (action != null && action.isNotEmpty) {
          _log.i('Intent action received: $action');
          _controller.add(action);
        }
      }
    });

    _flushPendingActions();
  }

  static Future<void> _flushPendingActions() async {
    try {
      final pending =
          await _channel.invokeListMethod<String>('getPendingActions') ?? [];
      for (final action in pending) {
        if (action.isNotEmpty) {
          _log.i('Flushing pending intent action: $action');
          _controller.add(action);
        }
      }
    } on PlatformException catch (e) {
      _log.w('Failed to get pending actions: ${e.message}');
    }
  }

  /// Report recording state to native so the Action Button can toggle.
  static Future<void> reportRecordingState({required bool isRecording}) async {
    try {
      await _channel.invokeMethod<void>('reportRecordingState', isRecording);
    } on PlatformException catch (e) {
      _log.w('Failed to report recording state: ${e.message}');
    } on MissingPluginException {
      // Expected in tests and on non-iOS platforms.
    }
  }

  static void dispose() {
    _controller.close();
  }
}
