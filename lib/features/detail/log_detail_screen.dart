import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/db/processing_state.dart';
import '../../core/db/providers.dart';
import 'entity_chips.dart';

/// Detail view for a single voice log — cleaned text (or raw with
/// shimmer while refining), entity chips at the top, delete/retry
/// actions planned for Phase 6.
class LogDetailScreen extends ConsumerWidget {
  const LogDetailScreen({super.key, required this.logId});

  final String logId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final logAsync = ref.watch(voiceLogByIdProvider(logId));
    final mentionsAsync = ref.watch(voiceLogMentionsProvider(logId));
    return Scaffold(
      appBar: AppBar(title: const Text('Log')),
      body: logAsync.when(
        data: (log) {
          if (log == null) {
            return const Center(child: Text('Log not found'));
          }
          final body = log.cleanedText ?? log.rawTranscript;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 8),
              mentionsAsync.maybeWhen(
                data: (mentions) => EntityChips(mentions: mentions),
                orElse: () => const SizedBox.shrink(),
              ),
              const SizedBox(height: 8),
              if (log.processingState == ProcessingState.recorded)
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: Text(
                    'refining…',
                    style: TextStyle(fontStyle: FontStyle.italic),
                  ),
                ),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: SelectableText(
                    body,
                    style: const TextStyle(fontSize: 16, height: 1.5),
                  ),
                ),
              ),
              if (log.processingState == ProcessingState.failed)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    'Refinement failed: ${log.errorMessage ?? "unknown"}',
                    style: const TextStyle(color: Colors.redAccent),
                  ),
                ),
            ],
          );
        },
        loading: () =>
            const Center(child: CircularProgressIndicator.adaptive()),
        error: (e, _) => Center(child: Text('Error: $e')),
      ),
    );
  }
}
