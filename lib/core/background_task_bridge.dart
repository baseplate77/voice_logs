import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import 'logger.dart';

/// Requests extra background execution time from iOS and bridges
/// BGTaskScheduler processing launches back into Dart.
///
/// `begin`/`end` use UIApplication background tasks for the short stop path.
/// `scheduleProcessingTask` uses BGTaskScheduler so durable queued jobs can be
/// resumed later by iOS without requiring network access.
///
/// No-op on non-iOS platforms.
class BackgroundTaskBridge {
  BackgroundTaskBridge._();

  static const _channel = MethodChannel('com.nj.voxsynth/background_task');
  static final _log = Logger('background_task');
  static final _processingController = StreamController<void>.broadcast();
  static bool _initialized = false;

  /// Emits when iOS launches the app for a BGProcessingTask.
  static Stream<void> get processingTasks => _processingController.stream;

  /// Register the native callback handler and flush a pending processing task
  /// that arrived before Dart finished booting.
  static void initialize() {
    if (_initialized) return;
    _initialized = true;
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onBackgroundProcessingTask':
          _processingController.add(null);
        case 'onBackgroundProcessingTaskExpired':
          _log.w('iOS background processing task expired');
        default:
          throw MissingPluginException('Unknown method ${call.method}');
      }
    });
    unawaited(_flushPendingProcessingTask());
  }

  static Future<void> _flushPendingProcessingTask() async {
    if (!Platform.isIOS) return;
    try {
      final pending =
          await _channel.invokeMethod<bool>('getPendingProcessingTask') ??
          false;
      if (pending) {
        _processingController.add(null);
      }
    } on PlatformException catch (e) {
      _log.w('Failed to get pending background processing task: ${e.message}');
    }
  }

  /// Request background execution time. Returns a task ID (or -1 on failure).
  static Future<int> begin() async {
    if (!Platform.isIOS) return -1;
    try {
      final taskId =
          await _channel.invokeMethod<int>('beginBackgroundTask') ?? -1;
      _log.i('Background task started: $taskId');
      return taskId;
    } on PlatformException catch (e) {
      _log.w('Failed to begin background task: ${e.message}');
      return -1;
    }
  }

  /// End a previously started background task.
  static Future<void> end(int taskId) async {
    if (!Platform.isIOS || taskId < 0) return;
    try {
      await _channel.invokeMethod<void>('endBackgroundTask', {
        'taskId': taskId,
      });
      _log.i('Background task ended: $taskId');
    } on PlatformException catch (e) {
      _log.w('Failed to end background task: ${e.message}');
    }
  }

  /// Schedule an iOS BGProcessingTask to resume queued jobs later.
  static Future<void> scheduleProcessingTask({
    Duration earliestBegin = const Duration(minutes: 1),
  }) async {
    if (!Platform.isIOS) return;
    try {
      await _channel.invokeMethod<bool>('scheduleProcessingTask', {
        'earliestBeginSeconds': earliestBegin.inMilliseconds / 1000,
      });
      _log.i('Scheduled iOS background processing task');
    } on PlatformException catch (e) {
      _log.w('Failed to schedule background processing task: ${e.message}');
    }
  }

  /// Cancel the queued iOS BGProcessingTask request.
  static Future<void> cancelProcessingTask() async {
    if (!Platform.isIOS) return;
    try {
      await _channel.invokeMethod<void>('cancelProcessingTask');
    } on PlatformException catch (e) {
      _log.w('Failed to cancel background processing task: ${e.message}');
    }
  }

  /// Mark the currently running iOS BGProcessingTask complete.
  static Future<void> completeProcessingTask({required bool success}) async {
    if (!Platform.isIOS) return;
    try {
      await _channel.invokeMethod<void>('completeProcessingTask', {
        'success': success,
      });
    } on PlatformException catch (e) {
      _log.w('Failed to complete background processing task: ${e.message}');
    }
  }
}
