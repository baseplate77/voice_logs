import '../../core/app_error.dart';
import '../../core/db/job_state.dart';
import '../../core/db/repositories/action_item_repository.dart';
import '../../core/db/repositories/voice_log_repository.dart';
import '../../core/result.dart';
import '../../core/worker/job_handler.dart';
import 'action_extractor.dart';
import 'action_types.dart';
import 'local_notification_scheduler.dart';

/// Worker handler for local action extraction and reminder notification setup.
class ActionJobHandler implements JobHandler {
  ActionJobHandler({
    required this.voiceLogs,
    required this.actions,
    required this.extractor,
    required this.notifications,
  });

  final VoiceLogRepository voiceLogs;
  final ActionItemRepository actions;
  final ActionExtractor extractor;
  final LocalNotificationScheduler notifications;

  @override
  JobType get type => JobType.action;

  @override
  Future<Result<JobOutcome, AppError>> handle(JobContext ctx) async {
    final log = await voiceLogs.find(ctx.logId);
    if (log == null) return const Ok(JobFailedPermanently('log not found'));
    final text = log.cleanedText ?? log.rawTranscript;
    if (text.trim().isEmpty) return const Ok(JobSucceeded());

    final extracted = await extractor.extract(text);
    final List<VoiceActionCandidate> candidates;
    switch (extracted) {
      case Ok(:final value):
        candidates = value;
      case Err(:final error):
        return Err(error);
    }

    final previous = await actions.forLog(ctx.logId);
    for (final item in previous) {
      final notificationId = item.notificationId;
      if (notificationId != null) {
        await notifications.cancel(notificationId);
      }
    }

    final stored = await actions.replaceForLog(
      voiceLogId: ctx.logId,
      candidates: candidates,
    );
    final List<VoiceActionItemView> items;
    switch (stored) {
      case Ok(:final value):
        items = value;
      case Err(:final error):
        return Err(error);
    }

    for (final item in items) {
      if (item.dueAt == null || !item.dueAt!.isAfter(DateTime.now())) continue;
      final scheduled = await notifications.scheduleActionReminder(item);
      switch (scheduled) {
        case Ok():
          await actions.markNotificationScheduled(
            id: item.id,
            scheduledAt: DateTime.now(),
          );
        case Err():
          // Notification permissions are best-effort. The action itself is
          // already safely stored in the inbox, so do not fail the pipeline.
          continue;
      }
    }

    return const Ok(JobSucceeded());
  }
}
