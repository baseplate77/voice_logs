import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/db/providers.dart';
import '../../core/result.dart';
import 'memory_types.dart';

/// One local memory card row with management actions.
class MemoryTile extends ConsumerWidget {
  const MemoryTile({required this.memory, super.key});

  final MemoryItemView memory;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListTile(
      title: Text(memory.text),
      subtitle: Text(_subtitle(memory)),
      isThreeLine: true,
      leading: Icon(_iconFor(memory.type)),
      trailing: PopupMenuButton<_MemoryAction>(
        onSelected: (action) => _handleAction(context, ref, action),
        itemBuilder: (context) => [
          if (memory.status != MemoryStatus.active)
            const PopupMenuItem(
              value: _MemoryAction.confirm,
              child: Text('Confirm'),
            ),
          const PopupMenuItem(
            value: _MemoryAction.archive,
            child: Text('Archive'),
          ),
          const PopupMenuItem(
            value: _MemoryAction.delete,
            child: Text('Delete'),
          ),
        ],
      ),
    );
  }

  Future<void> _handleAction(
    BuildContext context,
    WidgetRef ref,
    _MemoryAction action,
  ) async {
    final repo = ref.read(memoryRepositoryProvider);
    final result = switch (action) {
      _MemoryAction.confirm => await repo.confirm(memory.id),
      _MemoryAction.archive => await repo.archive(memory.id),
      _MemoryAction.delete => await repo.delete(memory.id),
    };
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

  String _subtitle(MemoryItemView memory) {
    final status = memory.status.wire;
    final sensitivity = memory.sensitivity.wire;
    final confidence = (memory.confidence * 100).round();
    return '${memory.type.wire} • $status • $sensitivity • $confidence% confidence';
  }

  IconData _iconFor(MemoryType type) => switch (type) {
    MemoryType.identity => Icons.badge_outlined,
    MemoryType.preference => Icons.tune,
    MemoryType.relationship => Icons.people_outline,
    MemoryType.project => Icons.work_outline,
    MemoryType.routine => Icons.repeat,
    MemoryType.place => Icons.place_outlined,
    MemoryType.eventContext => Icons.event_note_outlined,
  };
}

enum _MemoryAction { confirm, archive, delete }
