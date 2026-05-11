import 'package:flutter/material.dart';

/// Empty state shown before the first Ask message.
class AskEmptyState extends StatelessWidget {
  const AskEmptyState({super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.question_answer_outlined,
              size: 56,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(height: 16),
            Text(
              'Ask your voice journal',
              style: Theme.of(context).textTheme.titleLarge,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            const Text(
              'VoxSynth retrieves relevant local memories and voice-log snippets, '
              'then streams a structured answer from the on-device model.',
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
