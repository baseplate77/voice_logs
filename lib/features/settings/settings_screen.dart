import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/db/providers.dart';
import '../memory/memory_screen.dart';
import 'entities_screen.dart';

/// Minimal settings — canonical entities list and the destructive
/// "delete all" action. Export, storage usage, and thermal/battery
/// preferences are planned follow-ups.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          ListTile(
            leading: const Icon(Icons.memory_outlined),
            title: const Text('Memory'),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const MemoryScreen()),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.people_outline),
            title: const Text('Entities'),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const EntitiesScreen()),
            ),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.delete_forever, color: Colors.redAccent),
            title: const Text(
              'Delete all logs',
              style: TextStyle(color: Colors.redAccent),
            ),
            onTap: () => _confirmDeleteAll(context, ref),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmDeleteAll(BuildContext context, WidgetRef ref) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete everything?'),
        content: const Text(
          'This erases every voice log, transcript, and entity. '
          'Audio files on disk are untouched — they can be cleared '
          'via the OS.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    if (!context.mounted) return;
    final repo = ref.read(voiceLogRepositoryProvider);
    await repo.deleteAll();
  }
}
