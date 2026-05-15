import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/db/providers.dart';
import '../../core/result.dart';
import '../../core/worker/providers.dart';
import 'action_types.dart';

/// One row in the Action Inbox.
class VoiceActionTile extends ConsumerWidget {
  const VoiceActionTile({
    super.key,
    required this.action,
    required this.onOpenLog,
  });

  final VoiceActionItemView action;
  final ValueChanged<String> onOpenLog;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDone = action.status == VoiceActionStatus.done;
    return ListTile(
      leading: Checkbox(
        value: isDone,
        onChanged: isDone ? null : (_) => _markDone(context, ref),
      ),
      title: Text(
        action.title,
        style: isDone
            ? const TextStyle(decoration: TextDecoration.lineThrough)
            : null,
      ),
      subtitle: Text(_subtitle(action)),
      isThreeLine: action.notes != null || action.dueAt != null,
      trailing: PopupMenuButton<_ActionMenuItem>(
        onSelected: (item) => _handleMenu(context, ref, item),
        itemBuilder: (_) => [
          const PopupMenuItem(
            value: _ActionMenuItem.openLog,
            child: Text('Open source log'),
          ),
          if (!isDone)
            const PopupMenuItem(
              value: _ActionMenuItem.done,
              child: Text('Mark done'),
            ),
          const PopupMenuItem(
            value: _ActionMenuItem.archive,
            child: Text('Archive'),
          ),
          const PopupMenuItem(
            value: _ActionMenuItem.delete,
            child: Text('Delete'),
          ),
        ],
      ),
      onTap: () => onOpenLog(action.voiceLogId),
    );
  }

  Future<void> _handleMenu(
    BuildContext context,
    WidgetRef ref,
    _ActionMenuItem item,
  ) async {
    switch (item) {
      case _ActionMenuItem.openLog:
        onOpenLog(action.voiceLogId);
      case _ActionMenuItem.done:
        await _markDone(context, ref);
      case _ActionMenuItem.archive:
        await _archive(context, ref);
      case _ActionMenuItem.delete:
        await _delete(context, ref);
    }
  }

  Future<void> _markDone(BuildContext context, WidgetRef ref) async {
    await _cancelNotificationIfPresent(ref);
    final repo = ref.read(actionItemRepositoryProvider);
    final result = await repo.markDone(action.id);
    if (!context.mounted) return;
    switch (result) {
      case Ok():
        break;
      case Err(:final error):
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.message)));
    }
  }

  Future<void> _archive(BuildContext context, WidgetRef ref) async {
    await _cancelNotificationIfPresent(ref);
    final repo = ref.read(actionItemRepositoryProvider);
    final result = await repo.archive(action.id);
    if (!context.mounted) return;
    switch (result) {
      case Ok():
        break;
      case Err(:final error):
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.message)));
    }
  }

  Future<void> _delete(BuildContext context, WidgetRef ref) async {
    await _cancelNotificationIfPresent(ref);
    final repo = ref.read(actionItemRepositoryProvider);
    final result = await repo.delete(action.id);
    if (!context.mounted) return;
    switch (result) {
      case Ok():
        break;
      case Err(:final error):
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.message)));
    }
  }

  Future<void> _cancelNotificationIfPresent(WidgetRef ref) async {
    final notificationId = action.notificationId;
    if (notificationId == null) return;
    await ref.read(localNotificationSchedulerProvider).cancel(notificationId);
  }

  String _subtitle(VoiceActionItemView action) {
    final parts = <String>[_typeLabel(action.type)];
    final dueAt = action.dueAt;
    if (dueAt != null) parts.add('due ${_formatDateTime(dueAt)}');
    if (action.notificationScheduledAt != null) parts.add('notification set');
    if (action.notes != null && action.notes!.trim().isNotEmpty) {
      parts.add(action.notes!.trim());
    }
    return parts.join(' • ');
  }

  String _typeLabel(VoiceActionType type) => switch (type) {
    VoiceActionType.task => 'task',
    VoiceActionType.reminder => 'reminder',
    VoiceActionType.decision => 'decision',
    VoiceActionType.followUp => 'follow-up',
  };

  String _formatDateTime(DateTime dateTime) {
    final now = DateTime.now();
    final sameDay =
        now.year == dateTime.year &&
        now.month == dateTime.month &&
        now.day == dateTime.day;
    final h = dateTime.hour.toString().padLeft(2, '0');
    final m = dateTime.minute.toString().padLeft(2, '0');
    if (sameDay) return 'today $h:$m';
    return '${dateTime.month}/${dateTime.day} $h:$m';
  }
}

enum _ActionMenuItem { openLog, done, archive, delete }
