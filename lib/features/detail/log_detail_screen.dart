import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/db/job_state.dart';
import '../../core/db/processing_state.dart';
import '../../core/db/providers.dart';
import '../../core/worker/providers.dart';
import 'entity_chips.dart';

/// Detail view for a single voice log — cleaned text, entity chips,
/// and delete/retry-refine actions.
class LogDetailScreen extends ConsumerWidget {
  const LogDetailScreen({super.key, required this.logId});

  final String logId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final logAsync = ref.watch(voiceLogByIdProvider(logId));
    final mentionsAsync = ref.watch(voiceLogMentionsProvider(logId));
    return Scaffold(
      appBar: AppBar(
        title: const Text('Log'),
        actions: [
          logAsync.maybeWhen(
            data: (log) => log == null
                ? const SizedBox.shrink()
                : PopupMenuButton<String>(
                    onSelected: (v) => _onAction(context, ref, v),
                    itemBuilder: (_) => [
                      if (log.processingState == ProcessingState.failed)
                        const PopupMenuItem(
                          value: 'retry',
                          child: Text('Retry refinement'),
                        ),
                      const PopupMenuItem(
                        value: 'delete',
                        child: Text('Delete'),
                      ),
                    ],
                  ),
            orElse: () => const SizedBox.shrink(),
          ),
        ],
      ),
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

  Future<void> _onAction(
    BuildContext context,
    WidgetRef ref,
    String action,
  ) async {
    switch (action) {
      case 'retry':
        final queue = ref.read(jobQueueProvider);
        await queue.enqueue(logId: logId, type: JobType.refine);
      case 'delete':
        final repo = ref.read(voiceLogRepositoryProvider);
        final res = await repo.delete(logId);
        if (!context.mounted) return;
        if (res.isOk) Navigator.of(context).pop();
    }
  }
}
