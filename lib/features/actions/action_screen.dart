import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../core/db/providers.dart';
import '../detail/log_detail_screen.dart';
import 'action_tile.dart';
import 'action_types.dart';

/// Inbox for tasks, reminders, decisions, and follow-ups extracted locally from
/// voice logs.
class ActionScreen extends ConsumerWidget {
  const ActionScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final actions = ref.watch(actionItemsStreamProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Action Inbox')),
      body: actions.when(
        data: (items) {
          if (items.isEmpty) return const _EmptyState();
          final pending = items
              .where((a) => a.status == VoiceActionStatus.pending)
              .toList();
          final done = items
              .where((a) => a.status == VoiceActionStatus.done)
              .toList();
          return ListView(
            children: [
              if (pending.isNotEmpty) const _SectionHeader('Pending'),
              for (final action in pending)
                VoiceActionTile(
                  action: action,
                  onOpenLog: (logId) => _openLog(context, logId),
                ),
              if (pending.isNotEmpty && done.isNotEmpty) const Divider(),
              if (done.isNotEmpty) const _SectionHeader('Done'),
              for (final action in done)
                VoiceActionTile(
                  action: action,
                  onOpenLog: (logId) => _openLog(context, logId),
                ),
            ],
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) =>
            Center(child: Text('Failed to load actions: $error')),
      ),
    );
  }

  void _openLog(BuildContext context, String logId) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => LogDetailScreen(logId: logId)),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.label);
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
      child: Text(
        label.toUpperCase(),
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
          letterSpacing: 1.1,
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: EdgeInsets.all(24.r),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.check_circle_outline,
              size: 56.r,
              color: Theme.of(context).colorScheme.primary,
            ),
            SizedBox(height: 16.h),
            Text(
              'No actions yet',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            SizedBox(height: 8.h),
            const Text(
              'Tasks, reminders, decisions, and follow-ups extracted from your '
              'voice logs will appear here. Future reminders can schedule local '
              'device notifications.',
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
