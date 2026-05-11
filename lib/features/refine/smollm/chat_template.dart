/// SmolLM2 ChatML chat-template helpers.
///
/// SmolLM2-Instruct expects ChatML-shaped prompts:
///
///     <|im_start|>system
///     {system}<|im_end|>
///     <|im_start|>user
///     {user}<|im_end|>
///     <|im_start|>assistant
///
/// Special tokens (`<|im_start|>`, `<|im_end|>`) must be encoded as their
/// reserved single token ids — not as text. The tokenizer takes a
/// [ChatPrompt] and walks the [segments] list, emitting either special
/// token ids or BPE-encoded text bytes.
library;

/// One segment of a ChatML prompt — either a literal special token or a
/// run of plain text.
sealed class ChatSegment {
  const ChatSegment();
}

/// Special-token segment. The string must match a key in
/// `tokenizer_config.json`'s `added_tokens_decoder` map (e.g. `<|im_start|>`).
class ChatSpecial extends ChatSegment {
  const ChatSpecial(this.token);
  final String token;
}

/// Plain-text segment. Encoded via byte-level BPE.
class ChatText extends ChatSegment {
  const ChatText(this.text);
  final String text;
}

/// One ChatML message.
class ChatMessage {
  const ChatMessage({required this.role, required this.content});
  final String role;
  final String content;
}

/// Materialised ChatML prompt as an ordered list of segments. Hand to
/// `BpeTokenizer.encodeSegments` to produce token ids.
class ChatPrompt {
  const ChatPrompt(this.segments);
  final List<ChatSegment> segments;
}

/// Build a ChatML prompt from [messages]. The trailing
/// `<|im_start|>assistant\n` opens the generation slot — the model
/// continues from there until it emits `<|im_end|>`.
ChatPrompt buildChatMl(List<ChatMessage> messages) {
  final segments = <ChatSegment>[];
  for (final message in messages) {
    segments.add(const ChatSpecial('<|im_start|>'));
    segments.add(ChatText('${message.role}\n${message.content}'));
    segments.add(const ChatSpecial('<|im_end|>'));
    segments.add(const ChatText('\n'));
  }
  segments.add(const ChatSpecial('<|im_start|>'));
  segments.add(const ChatText('assistant\n'));
  return ChatPrompt(segments);
}

/// Convenience for a single user turn with optional system message.
ChatPrompt singleUserPrompt({String? system, required String user}) {
  return buildChatMl([
    if (system != null) ChatMessage(role: 'system', content: system),
    ChatMessage(role: 'user', content: user),
  ]);
}
