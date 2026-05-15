import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voxsynth/core/app_error.dart';
import 'package:voxsynth/core/db/database.dart';
import 'package:voxsynth/core/db/repositories/action_item_repository.dart';
import 'package:voxsynth/core/db/repositories/voice_log_repository.dart';
import 'package:voxsynth/core/result.dart';
import 'package:voxsynth/core/worker/job_handler.dart';
import 'package:voxsynth/features/actions/action_extractor.dart';
import 'package:voxsynth/features/actions/action_job.dart';
import 'package:voxsynth/features/actions/action_types.dart';
import 'package:voxsynth/features/actions/local_notification_scheduler.dart';
import 'package:voxsynth/features/refine/llm_runner.dart';

void main() {
  late VoxSynthDatabase db;
  late VoiceLogRepository logs;
  late ActionItemRepository actions;
  late _FakeNotifications notifications;

  setUp(() async {
    db = VoxSynthDatabase(NativeDatabase.memory());
    logs = VoiceLogRepository(db);
    actions = ActionItemRepository(db);
    notifications = _FakeNotifications();
    await logs.insertRecorded(
      id: 'log_1',
      createdAt: DateTime(2026, 5, 14),
      durationMs: 1000,
      audioPath: 'audio/log_1.wav',
      rawTranscript: 'Call Dr. Rao at 9:30 tomorrow.',
    );
    await logs.markRefined(
      id: 'log_1',
      cleanedText: 'Call Dr. Rao at 9:30 tomorrow.',
    );
  });

  tearDown(() => db.close());

  test('stores actions and schedules future reminder notification', () async {
    final runner = _FakeRunner(
      '{"actions":[{"type":"reminder","title":"Call Dr. Rao","due_at":"2099-05-15T09:30:00","evidence":"Call Dr. Rao at 9:30 tomorrow","confidence":0.92}]}',
    );
    final handler = ActionJobHandler(
      voiceLogs: logs,
      actions: actions,
      extractor: ActionExtractor(
        runner: runner,
        now: () => DateTime(2026, 5, 14, 12),
      ),
      notifications: notifications,
    );

    final res = await handler.handle(
      const JobContext(jobId: 'job_1', logId: 'log_1', attempts: 0),
    );

    expect(res, isA<Ok<JobOutcome, AppError>>());
    expect(await actions.watchInbox().first, hasLength(1));
    expect(notifications.scheduled, hasLength(1));
    final stored = (await actions.watchInbox().first).single;
    expect(stored.notificationScheduledAt, isNotNull);
  });
}

class _FakeRunner implements LlmRunner {
  _FakeRunner(this.response);
  final String response;

  @override
  Future<void> dispose() async {}

  @override
  Future<Result<String, LlmError>> generate(
    String prompt, {
    double temperature = 0.3,
    int topK = 1,
    double topP = 0.95,
    int? randomSeed,
  }) async => Ok(response);

  @override
  Future<Result<void, LlmError>> load() async => const Ok(null);

  @override
  Future<void> unload() async {}
}

class _FakeNotifications implements LocalNotificationScheduler {
  final scheduled = <VoiceActionItemView>[];

  @override
  Future<Result<void, LocalNotificationError>> cancel(
    int notificationId,
  ) async {
    return const Ok(null);
  }

  @override
  Future<Result<void, LocalNotificationError>> scheduleActionReminder(
    VoiceActionItemView action,
  ) async {
    scheduled.add(action);
    return const Ok(null);
  }
}
