import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

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
            return Center(
              child: Padding(
                padding: EdgeInsets.all(24.r),
                child: const Text(
                  'No memories yet. Durable memories will appear here after '
                  'voice logs are refined and processed locally.',
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }
          return ListView.separated(
            itemCount: items.length,
            separatorBuilder: (_, _) => Divider(height: 1.h),
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
