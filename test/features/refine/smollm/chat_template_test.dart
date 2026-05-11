import 'package:flutter_test/flutter_test.dart';
import 'package:voxsynth/features/refine/smollm/chat_template.dart';

void main() {
  group('buildChatMl', () {
    test('emits <|im_start|>{role}\\n{body}<|im_end|>\\n per message', () {
      final prompt = buildChatMl(const [
        ChatMessage(role: 'user', content: 'hi'),
      ]);
      expect(prompt.segments, hasLength(6));
      expect(prompt.segments[0], isA<ChatSpecial>());
      expect((prompt.segments[0] as ChatSpecial).token, '<|im_start|>');
      expect((prompt.segments[1] as ChatText).text, 'user\nhi');
      expect((prompt.segments[2] as ChatSpecial).token, '<|im_end|>');
      expect((prompt.segments[3] as ChatText).text, '\n');
      expect((prompt.segments[4] as ChatSpecial).token, '<|im_start|>');
      expect((prompt.segments[5] as ChatText).text, 'assistant\n');
    });

    test('singleUserPrompt prepends optional system message', () {
      final withoutSystem = singleUserPrompt(user: 'hi');
      expect(
        withoutSystem.segments.whereType<ChatText>().map((c) => c.text),
        containsAllInOrder(['user\nhi', '\n', 'assistant\n']),
      );

      final withSystem = singleUserPrompt(system: 'be terse', user: 'hi');
      final texts = withSystem.segments
          .whereType<ChatText>()
          .map((c) => c.text)
          .toList();
      expect(texts, containsAllInOrder(['system\nbe terse', '\n', 'user\nhi']));
    });
  });
}
