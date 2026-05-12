import 'package:flutter_test/flutter_test.dart';
import 'package:voxsynth/core/vox_intent_action.dart';

void main() {
  group('VoxIntentAction.parse', () {
    test('parses recording controls', () {
      expect(VoxIntentAction.parse('start'), isA<StartRecordingAction>());
      expect(VoxIntentAction.parse('stop'), isA<StopRecordingAction>());
    });

    test('parses app open action', () {
      expect(VoxIntentAction.parse('open'), isA<OpenAppAction>());
    });

    test('parses and decodes log open action', () {
      final parsed = VoxIntentAction.parse('openLog:log_123%20456');

      expect(parsed, isA<OpenVoiceLogAction>());
      expect((parsed! as OpenVoiceLogAction).logId, 'log_123 456');
    });

    test('ignores malformed actions', () {
      expect(VoxIntentAction.parse(''), isNull);
      expect(VoxIntentAction.parse('openLog:'), isNull);
      expect(VoxIntentAction.parse('openLog:%E0%A4%A'), isNull);
      expect(VoxIntentAction.parse('somethingElse'), isNull);
    });
  });
}
