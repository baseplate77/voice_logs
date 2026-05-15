import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/db/providers.dart';
import '../actions/action_screen.dart';
import '../backup/export_screen.dart';
import '../backup/import_screen.dart';
import '../eval/refine_eval_screen.dart';
import '../home/auto_record_provider.dart';
import '../memory/memory_screen.dart';
import 'entities_screen.dart';
import 'shortcuts_setup_screen.dart';

/// Minimal settings — canonical entities list and the destructive
/// "delete all" action. Export, storage usage, and thermal/battery
/// preferences are planned follow-ups.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          _AutoRecordTile(),
          ListTile(
            leading: const Icon(Icons.shortcut_outlined),
            title: const Text('Quick access'),
            subtitle: const Text('Siri, Action Button, Lock Screen, Back Tap'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const ShortcutsSetupScreen(),
              ),
            ),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.check_circle_outline),
            title: const Text('Action Inbox'),
            subtitle: const Text('Tasks, reminders, decisions, follow-ups'),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const ActionScreen()),
            ),
          ),
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
          ListTile(
            leading: const Icon(Icons.science_outlined),
            title: const Text('Refine eval'),
            subtitle: const Text('Run SmolLM2 on the 50-case fixture'),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const RefineEvalScreen()),
            ),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.lock_outline),
            title: const Text('Export encrypted backup'),
            subtitle: const Text('Logs, transcripts, audio, memories'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const ExportBackupScreen(),
              ),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.file_open_outlined),
            title: const Text('Import encrypted backup'),
            subtitle: const Text('Merge a .voxsynth file into this device'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const ImportBackupScreen(),
              ),
            ),
          ),
          const Divider(height: 1),
          ListTile(
            leading: Icon(Icons.delete_forever, color: scheme.error),
            title: Text(
              'Delete all logs',
              style: TextStyle(color: scheme.error),
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
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
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

class _AutoRecordTile extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final enabled = ref.watch(autoRecordEnabledProvider);
    return SwitchListTile(
      secondary: const Icon(Icons.play_circle_outline),
      title: const Text('Record on launch'),
      subtitle: const Text('Start recording when the app opens'),
      value: enabled,
      onChanged: (_) => ref.read(autoRecordEnabledProvider.notifier).toggle(),
    );
  }
}
