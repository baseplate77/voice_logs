import 'package:flutter/material.dart';

/// Bottom input composer for the Ask chat screen.
class AskComposer extends StatelessWidget {
  const AskComposer({
    super.key,
    required this.controller,
    required this.loading,
    required this.onSubmit,
  });

  /// Text controller for the question input.
  final TextEditingController controller;

  /// Whether a response is currently streaming.
  final bool loading;

  /// Called when the user submits a question.
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Material(
      elevation: 8,
      color: colorScheme.surface,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: TextField(
                controller: controller,
                enabled: !loading,
                minLines: 1,
                maxLines: 5,
                textInputAction: TextInputAction.send,
                decoration: InputDecoration(
                  hintText: loading
                      ? 'Streaming answer…'
                      : 'Ask about your voice logs…',
                  filled: true,
                  fillColor: colorScheme.surfaceContainerHighest,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                    borderSide: BorderSide.none,
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                ),
                onSubmitted: (_) {
                  if (!loading) onSubmit();
                },
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: loading ? null : onSubmit,
              style: FilledButton.styleFrom(
                shape: const CircleBorder(),
                padding: const EdgeInsets.all(14),
              ),
              child: loading
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.arrow_upward),
            ),
          ],
        ),
      ),
    );
  }
}
