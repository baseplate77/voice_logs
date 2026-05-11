import '../memory/memory_types.dart';
import '../search/hybrid_retriever.dart';

/// Role for a message in the Ask conversation.
enum AskChatRole { user, assistant }

/// Immutable chat message used by [AskScreen].
class AskChatMessage {
  const AskChatMessage({
    required this.id,
    required this.role,
    required this.text,
    required this.streaming,
    this.memoryHits = const [],
    this.logHits = const [],
  });

  /// User message factory.
  factory AskChatMessage.user(String text) => AskChatMessage(
    id: 'user_${DateTime.now().microsecondsSinceEpoch}',
    role: AskChatRole.user,
    text: text,
    streaming: false,
  );

  /// Assistant message factory.
  factory AskChatMessage.assistant({
    required String id,
    required String text,
    required bool streaming,
  }) => AskChatMessage(
    id: id,
    role: AskChatRole.assistant,
    text: text,
    streaming: streaming,
  );

  /// Stable message id.
  final String id;

  /// Message role.
  final AskChatRole role;

  /// Message text.
  final String text;

  /// Whether this assistant message is still streaming.
  final bool streaming;

  /// Retrieved memory context attached to this answer.
  final List<MemoryHit> memoryHits;

  /// Retrieved voice-log context attached to this answer.
  final List<SearchHit> logHits;

  /// Return a copy with selected fields changed.
  AskChatMessage copyWith({
    String? text,
    bool? streaming,
    List<MemoryHit>? memoryHits,
    List<SearchHit>? logHits,
  }) {
    return AskChatMessage(
      id: id,
      role: role,
      text: text ?? this.text,
      streaming: streaming ?? this.streaming,
      memoryHits: memoryHits ?? this.memoryHits,
      logHits: logHits ?? this.logHits,
    );
  }
}
