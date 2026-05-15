import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voxsynth/core/db/database.dart';
import 'package:voxsynth/core/db/repositories/action_item_repository.dart';
import 'package:voxsynth/core/db/repositories/voice_log_repository.dart';
import 'package:voxsynth/core/result.dart';
import 'package:voxsynth/features/actions/action_types.dart';

void main() {
  late VoxSynthDatabase db;
  late VoiceLogRepository logs;
  late ActionItemRepository actions;

  setUp(() async {
    db = VoxSynthDatabase(NativeDatabase.memory());
    logs = VoiceLogRepository(db);
    actions = ActionItemRepository(db);
    await logs.insertRecorded(
      id: 'log_1',
      createdAt: DateTime(2026, 5, 14),
      durationMs: 1000,
      audioPath: 'audio/log_1.wav',
      rawTranscript: 'Call Dr. Rao tomorrow.',
    );
  });

  tearDown(() => db.close());

  test('replaceForLog stores pending action with source evidence', () async {
    final res = await actions.replaceForLog(
      voiceLogId: 'log_1',
      candidates: [
        VoiceActionCandidate(
          type: VoiceActionType.reminder,
          title: 'Call Dr. Rao',
          dueAt: DateTime(2026, 5, 15, 9),
          evidence: 'Call Dr. Rao tomorrow',
          startChar: 0,
          endChar: 21,
          confidence: 0.9,
        ),
      ],
    );

    expect(
      res,
      isA<Ok<List<VoiceActionItemView>, ActionItemRepositoryError>>(),
    );
    final item =
        (res as Ok<List<VoiceActionItemView>, ActionItemRepositoryError>)
            .value
            .single;
    expect(item.status, VoiceActionStatus.pending);
    expect(item.notificationId, isNotNull);
    expect(item.evidenceText, 'Call Dr. Rao tomorrow');

    final watched = await actions.watchInbox().first;
    expect(watched.single.title, 'Call Dr. Rao');
  });

  test('markDone and archive update inbox visibility', () async {
    final stored = await actions.replaceForLog(
      voiceLogId: 'log_1',
      candidates: const [
        VoiceActionCandidate(
          type: VoiceActionType.task,
          title: 'Send notes',
          evidence: 'Call Dr. Rao',
          startChar: 0,
          endChar: 12,
        ),
      ],
    );
    final item =
        (stored as Ok<List<VoiceActionItemView>, ActionItemRepositoryError>)
            .value
            .single;

    expect((await actions.markDone(item.id)).isOk, isTrue);
    expect((await actions.find(item.id))!.status, VoiceActionStatus.done);

    expect((await actions.archive(item.id)).isOk, isTrue);
    expect(await actions.watchInbox().first, isEmpty);
  });
}
