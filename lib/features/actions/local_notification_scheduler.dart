import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

import '../../core/app_error.dart';
import '../../core/logger.dart';
import '../../core/result.dart';
import 'action_types.dart';

/// Errors from local notification scheduling.
sealed class LocalNotificationError extends AppError {
  const LocalNotificationError({
    required super.message,
    super.cause,
    super.stack,
  });
}

/// Wraps platform notification failures.
final class LocalNotificationPlatformError extends LocalNotificationError {
  const LocalNotificationPlatformError({
    required super.message,
    super.cause,
    super.stack,
  });
}

/// Schedules/cancels local device notifications for extracted reminders.
abstract class LocalNotificationScheduler {
  /// Schedule a local reminder for [action]. Implementations should no-op for
  /// actions without a future [VoiceActionItemView.dueAt].
  Future<Result<void, LocalNotificationError>> scheduleActionReminder(
    VoiceActionItemView action,
  );

  /// Cancel a previously scheduled local notification.
  Future<Result<void, LocalNotificationError>> cancel(int notificationId);
}

/// `flutter_local_notifications` implementation. All work stays on-device.
class FlutterLocalNotificationScheduler implements LocalNotificationScheduler {
  FlutterLocalNotificationScheduler({FlutterLocalNotificationsPlugin? plugin})
    : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final FlutterLocalNotificationsPlugin _plugin;
  final _log = Logger('local_notifications');
  bool _initialized = false;

  @override
  Future<Result<void, LocalNotificationError>> scheduleActionReminder(
    VoiceActionItemView action,
  ) async {
    final dueAt = action.dueAt;
    final notificationId = action.notificationId;
    if (dueAt == null || notificationId == null) return const Ok(null);
    if (!dueAt.isAfter(DateTime.now())) return const Ok(null);

    try {
      await _ensureInitialized();
      await _requestPermissionsIfNeeded();
      await _plugin.zonedSchedule(
        id: notificationId,
        title: 'VoxSynth reminder',
        body: action.title,
        scheduledDate: tz.TZDateTime.from(dueAt, tz.local),
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            'voxsynth_actions',
            'Action reminders',
            channelDescription: 'Local reminders extracted from voice logs',
            importance: Importance.high,
            priority: Priority.high,
          ),
          iOS: DarwinNotificationDetails(),
        ),
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        payload: action.voiceLogId,
      );
      return const Ok(null);
    } on Object catch (e, s) {
      _log.w('Failed to schedule action reminder', error: e, stack: s);
      return Err(
        LocalNotificationPlatformError(
          message: 'Failed to schedule reminder notification: $e',
          cause: e,
          stack: s,
        ),
      );
    }
  }

  @override
  Future<Result<void, LocalNotificationError>> cancel(
    int notificationId,
  ) async {
    try {
      await _ensureInitialized();
      await _plugin.cancel(id: notificationId);
      return const Ok(null);
    } on Object catch (e, s) {
      return Err(
        LocalNotificationPlatformError(
          message: 'Failed to cancel reminder notification: $e',
          cause: e,
          stack: s,
        ),
      );
    }
  }

  Future<void> _ensureInitialized() async {
    if (_initialized) return;
    tz_data.initializeTimeZones();
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const ios = DarwinInitializationSettings();
    await _plugin.initialize(
      settings: const InitializationSettings(android: android, iOS: ios),
    );
    _initialized = true;
  }

  Future<void> _requestPermissionsIfNeeded() async {
    if (Platform.isIOS || Platform.isMacOS) {
      await _plugin
          .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin
          >()
          ?.requestPermissions(alert: true, badge: true, sound: true);
      return;
    }
    if (Platform.isAndroid) {
      await _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.requestNotificationsPermission();
    }
  }
}
