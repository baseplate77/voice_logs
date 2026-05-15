import 'package:flutter_test/flutter_test.dart';
import 'package:voxsynth/features/actions/action_extractor.dart';
import 'package:voxsynth/features/actions/action_types.dart';

void main() {
  test('parseActionCandidates validates evidence and due date', () {
    const cleaned =
        'Tasks for tomorrow: Call Dr. Rao at 9:30. Send Project Atlas notes to Shivani.';
    final actions = parseActionCandidates(
      '{"actions":[{"type":"reminder","title":"Call Dr. Rao","due_at":"2026-05-15T09:30:00","evidence":"Call Dr. Rao at 9:30","confidence":0.92},{"type":"task","title":"Send Project Atlas notes to Shivani","evidence":"Send Project Atlas notes to Shivani","confidence":0.9}]}',
      cleanedText: cleaned,
    );

    expect(actions, isNotNull);
    expect(actions, hasLength(2));
    expect(actions![0].type, VoiceActionType.reminder);
    expect(actions[0].dueAt, DateTime(2026, 5, 15, 9, 30));
    expect(actions[0].evidence, 'Call Dr. Rao at 9:30');
    expect(actions[1].type, VoiceActionType.task);
  });

  test('parseActionCandidates drops invalid evidence', () {
    final actions = parseActionCandidates(
      '{"actions":[{"type":"task","title":"Invented task","evidence":"not in transcript","confidence":0.9}]}',
      cleanedText: 'Buy milk tonight.',
    );

    expect(actions, isEmpty);
  });
}
