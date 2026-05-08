import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/db/providers.dart';
import '../debug/pipeline_debug_screen.dart';
import '../detail/log_detail_screen.dart';
import '../record/record_screen.dart';
import '../search/search_screen.dart';
import '../settings/settings_screen.dart';
import 'log_row.dart';

/// Reverse-chronological list of voice logs with search + settings
/// entry points in the app bar and a large Record FAB.
class HomeListScreen extends ConsumerWidget {
  const HomeListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final logs = ref.watch(voiceLogsStreamProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('VoxSynth'),
        actions: [
          IconButton(
            tooltip: 'Pipeline debug',
            icon: const Icon(Icons.bug_report_outlined),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const PipelineDebugScreen(),
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.search),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const SearchScreen()),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const SettingsScreen()),
            ),
          ),
        ],
      ),
      body: logs.when(
        data: (rows) {
          if (rows.isEmpty) return const _EmptyState();
          return ListView.separated(
            itemCount: rows.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (_, i) {
              final row = rows[i];
              return LogRow(
                log: row,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => LogDetailScreen(logId: row.id),
                  ),
                ),
              );
            },
          );
        },
        loading: () =>
            const Center(child: CircularProgressIndicator.adaptive()),
        error: (e, _) => Center(child: Text('Error: $e')),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => Navigator.of(
          context,
        ).push(MaterialPageRoute<void>(builder: (_) => const RecordScreen())),
        icon: const Icon(Icons.mic),
        label: const Text('Record'),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(24),
        child: Text(
          'Your journal gets smarter as you record more.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 18),
        ),
      ),
    );
  }
}
