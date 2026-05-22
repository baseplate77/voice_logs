import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../app_theme.dart';
import '../../core/db/providers.dart';
import '../detail/log_detail_screen.dart';
import '../record/record_screen.dart';
import '../search/search_screen.dart';
import 'log_row.dart';

/// Reverse-chronological list of voice logs with a compact title/search
/// app bar and a large Record FAB.
class HomeListScreen extends ConsumerWidget {
  const HomeListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final logs = ref.watch(voiceLogsStreamProvider);
    return Scaffold(
      appBar: AppBar(
        title: Text.rich(
          TextSpan(
            children: [
              TextSpan(
                text: 'VoxSynth',
                style: TextStyle(
                  fontFamily: 'NDOT',
                  fontWeight: FontWeight.bold,
                  fontSize: 20.sp,
                  color: VoxAppColors.primary,
                ),
              ),
              TextSpan(
                text: '.',
                style: TextStyle(
                  fontFamily: 'NDOT',
                  fontWeight: FontWeight.bold,
                  fontSize: 20.sp,
                  color: VoxAppColors.accent,
                ),
              ),
            ],
          ),
        ),
        actions: [
          Padding(
            padding: EdgeInsets.only(right: 12.w),
            child: IconButton.filledTonal(
              tooltip: 'Search journal',
              icon: const Icon(Icons.search_rounded),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const SearchScreen()),
              ),
            ),
          ),
        ],
      ),
      body: logs.when(
        data: (rows) {
          if (rows.isEmpty) return const _EmptyState();
          return ListView.separated(
            padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 8.h),
            itemCount: rows.length,
            separatorBuilder: (_, _) => SizedBox(height: 6.h),
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
    return Center(
      child: Padding(
        padding: EdgeInsets.all(24.r),
        child: Text(
          'Your journal gets smarter as you record more.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 18.sp),
        ),
      ),
    );
  }
}
