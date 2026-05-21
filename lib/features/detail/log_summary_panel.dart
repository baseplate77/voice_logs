import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../core/db/providers.dart';
import '../../core/db/repositories/log_summary_repository.dart';

/// Renders the per-log structured summary (one-liner, bullets,
/// people/projects, decisions, follow-ups). Hides itself when no summary
/// row exists for [logId] — empty state is silent so the detail screen
/// doesn't grow placeholders while the summarize job is still pending.
class LogSummaryPanel extends ConsumerWidget {
  const LogSummaryPanel({super.key, required this.logId});

  final String logId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(logSummaryForLogProvider(logId));
    final summary = async.value;
    if (summary == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: _SummaryCard(summary: summary),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.summary});

  final LogSummaryView summary;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sections = <Widget>[];
    if (summary.bullets.isNotEmpty) {
      sections.add(
        _SummarySection(title: 'Key points', items: summary.bullets),
      );
    }
    if (summary.peopleProjects.isNotEmpty) {
      sections.add(
        _SummarySection(
          title: 'People & projects',
          items: summary.peopleProjects,
        ),
      );
    }
    if (summary.decisions.isNotEmpty) {
      sections.add(
        _SummarySection(title: 'Decisions', items: summary.decisions),
      );
    }
    if (summary.followUps.isNotEmpty) {
      sections.add(
        _SummarySection(title: 'Follow-ups', items: summary.followUps),
      );
    }

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: EdgeInsets.all(12.r),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              summary.oneLiner,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            for (final section in sections) ...[SizedBox(height: 8.h), section],
          ],
        ),
      ),
    );
  }
}

class _SummarySection extends StatelessWidget {
  const _SummarySection({required this.title, required this.items});

  final String title;
  final List<String> items;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: theme.textTheme.labelLarge?.copyWith(
            color: theme.colorScheme.primary,
          ),
        ),
        SizedBox(height: 4.h),
        for (final item in items)
          Padding(
            padding: EdgeInsets.only(bottom: 2.h),
            child: Text('• $item', style: theme.textTheme.bodyMedium),
          ),
      ],
    );
  }
}
