import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/db/providers.dart';
import 'memory_tile.dart';

/// Local memory management screen. Users can inspect, confirm, archive, and
/// delete memory cards without affecting the source voice logs.
class MemoryScreen extends ConsumerWidget {
  const MemoryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final memories = ref.watch(memoryItemsStreamProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Memory')),
      body: memories.when(
        data: (items) {
          if (items.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'No memories yet. Durable memories will appear here after '
                  'voice logs are refined and processed locally.',
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }
          return ListView.separated(
            itemCount: items.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, index) => MemoryTile(memory: items[index]),
          );
        },
        error: (error, _) =>
            Center(child: Text('Failed to load memory: $error')),
        loading: () => const Center(child: CircularProgressIndicator()),
      ),
    );
  }
}
