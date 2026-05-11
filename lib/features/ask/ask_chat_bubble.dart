import 'package:flutter/material.dart';

import '../detail/markdown_transcript_view.dart';
import 'ask_chat_message.dart';
import 'ask_context_panel.dart';

/// Chat bubble for one Ask message.
class AskChatBubble extends StatelessWidget {
  const AskChatBubble({
    super.key,
    required this.message,
    required this.onOpenLog,
  });

  /// Message to render.
  final AskChatMessage message;

  /// Called when a voice-log context source is opened.
  final ValueChanged<String> onOpenLog;

  @override
  Widget build(BuildContext context) {
    final isUser = message.role == AskChatRole.user;
    final colorScheme = Theme.of(context).colorScheme;
    final background = isUser
        ? colorScheme.primaryContainer
        : colorScheme.surfaceContainerHighest;
    final foreground = isUser
        ? colorScheme.onPrimaryContainer
        : colorScheme.onSurfaceVariant;

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.86,
        ),
        child: Card(
          elevation: 0,
          color: background,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(20),
              topRight: const Radius.circular(20),
              bottomLeft: Radius.circular(isUser ? 20 : 6),
              bottomRight: Radius.circular(isUser ? 6 : 20),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: DefaultTextStyle.merge(
              style: TextStyle(color: foreground),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (isUser)
                    SelectableText(message.text)
                  else
                    MarkdownTranscriptView(
                      text: message.text,
                      mentions: const [],
                    ),
                  if (message.streaming) ...[
                    const SizedBox(height: 8),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox.square(
                          dimension: 12,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: foreground,
                          ),
                        ),
                        const SizedBox(width: 8),
                        const Text('Streaming locally'),
                      ],
                    ),
                  ],
                  if (!isUser &&
                      !message.streaming &&
                      (message.memoryHits.isNotEmpty ||
                          message.logHits.isNotEmpty)) ...[
                    const SizedBox(height: 8),
                    AskContextPanel(message: message, onOpenLog: onOpenLog),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
