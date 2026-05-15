import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/db/providers.dart';
import '../../core/db/repositories/log_summary_repository.dart';
import '../../core/pipeline_debug.dart';
import '../../core/pipeline_debug_provider.dart';
import '../../core/worker/providers.dart';
import '../digest/digest_runner.dart';

/// In-app debug timeline for per-log pipeline stages and durations.
class PipelineDebugScreen extends ConsumerWidget {
  /// Creates the pipeline debug screen.
  const PipelineDebugScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entries = ref.watch(pipelineDebugProvider);
    final groups = _groupEntries(entries);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Pipeline debug'),
        actions: [
          IconButton(
            tooltip: 'Clear debug log',
            icon: const Icon(Icons.delete_outline),
            onPressed: entries.isEmpty
                ? null
                : () => ref.read(pipelineDebugProvider.notifier).clear(),
          ),
        ],
      ),
      body: ListView(
        children: [
          const _DigestTestPanel(),
          if (groups.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'No pipeline events yet. Record a log to see timings.',
                textAlign: TextAlign.center,
              ),
            )
          else
            for (final group in groups) _LogDebugGroup(group: group),
        ],
      ),
    );
  }

  List<_DebugGroup> _groupEntries(List<PipelineDebugEntry> entries) {
    final byLog = <String, List<PipelineDebugEntry>>{};
    for (final entry in entries) {
      final key = entry.logId ?? 'App / worker';
      byLog.putIfAbsent(key, () => []).add(entry);
    }
    final groups = byLog.entries.map((entry) {
      final sorted = [...entry.value]
        ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
      return _DebugGroup(logId: entry.key, entries: sorted);
    }).toList();
    groups.sort((a, b) => b.latest.compareTo(a.latest));
    return groups;
  }
}

class _DigestTestPanel extends ConsumerWidget {
  const _DigestTestPanel();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final today = DigestTarget.today();
    final week = DigestTarget.weekEndingOn();
    final repo = ref.watch(logSummaryRepositoryProvider);

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Digests', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              'Generate a cross-log daily or weekly digest from the existing logs. '
              'On-demand only — no scheduled jobs.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    icon: const Icon(Icons.today_outlined),
                    label: const Text("Generate today's digest"),
                    onPressed: () => _enqueue(context, ref, today),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton.tonalIcon(
                    icon: const Icon(Icons.view_week_outlined),
                    label: const Text("Generate this week's digest"),
                    onPressed: () => _enqueue(context, ref, week),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _DigestPreview(
              title: 'Today · ${today.windowKey}',
              stream: repo.watchDigest(
                kind: today.kind,
                windowKey: today.windowKey,
              ),
            ),
            const SizedBox(height: 8),
            _DigestPreview(
              title: 'This week · ${week.label}',
              stream: repo.watchDigest(
                kind: week.kind,
                windowKey: week.windowKey,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _enqueue(
    BuildContext context,
    WidgetRef ref,
    DigestTarget target,
  ) async {
    final queue = ref.read(jobQueueProvider);
    // Wake the worker if it's idle so the job picks up immediately.
    unawaited(ref.read(workerProvider).start());
    final jobId = await enqueueDigest(queue: queue, target: target);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Enqueued ${target.wire} (job $jobId)')),
    );
  }
}

class _DigestPreview extends StatelessWidget {
  const _DigestPreview({required this.title, required this.stream});

  final String title;
  final Stream<DigestView?> stream;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return StreamBuilder<DigestView?>(
      stream: stream,
      builder: (context, snapshot) {
        final digest = snapshot.data;
        return Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            border: Border.all(color: Theme.of(context).dividerColor),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: textTheme.labelLarge),
              const SizedBox(height: 6),
              if (digest == null)
                Text(
                  'No digest yet. Tap the button above to generate.',
                  style: textTheme.bodySmall,
                )
              else
                _DigestBody(digest: digest),
            ],
          ),
        );
      },
    );
  }
}

class _DigestBody extends StatelessWidget {
  const _DigestBody({required this.digest});

  final DigestView digest;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(digest.oneLiner, style: textTheme.bodyMedium),
        if (digest.bullets.isNotEmpty) ...[
          const SizedBox(height: 8),
          for (final bullet in digest.bullets)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Text('• $bullet', style: textTheme.bodySmall),
            ),
        ],
        _DigestList(label: _topicsLabel(digest.kind), items: digest.topics),
        _DigestList(label: _actionsLabel(digest.kind), items: digest.actions),
        _DigestList(
          label: _decisionsLabel(digest.kind),
          items: digest.decisions,
        ),
        if (digest.mood != null && digest.mood!.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text('Mood: ${digest.mood}', style: textTheme.bodySmall),
        ],
        const SizedBox(height: 6),
        Text(
          'Generated ${_clock(digest.generatedAt)}',
          style: textTheme.labelSmall,
        ),
      ],
    );
  }

  String _topicsLabel(DigestKind kind) =>
      kind == DigestKind.daily ? 'People mentioned' : 'Project progress';

  String _actionsLabel(DigestKind kind) =>
      kind == DigestKind.daily ? 'Tasks created' : 'Unfinished tasks';

  String _decisionsLabel(DigestKind kind) =>
      kind == DigestKind.daily ? 'Decisions' : 'Repeated concerns';

  String _clock(DateTime t) {
    final h = t.hour.toString().padLeft(2, '0');
    final m = t.minute.toString().padLeft(2, '0');
    return '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')} $h:$m';
  }
}

class _DigestList extends StatelessWidget {
  const _DigestList({required this.label, required this.items});

  final String label;
  final List<String> items;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: textTheme.labelMedium),
          for (final item in items)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 1),
              child: Text('• $item', style: textTheme.bodySmall),
            ),
        ],
      ),
    );
  }
}

class _DebugGroup {
  const _DebugGroup({required this.logId, required this.entries});

  final String logId;
  final List<PipelineDebugEntry> entries;

  DateTime get latest => entries.last.timestamp;
}

class _LogDebugGroup extends StatelessWidget {
  const _LogDebugGroup({required this.group});

  final _DebugGroup group;

  @override
  Widget build(BuildContext context) {
    final latest = group.entries.last;
    final latestElapsed = latest.elapsedLabel;
    final subtitle = latestElapsed.isEmpty
        ? '${latest.stage.label} • ${latest.event}'
        : '${latest.stage.label} • ${latest.event} • $latestElapsed';
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: ExpansionTile(
        initiallyExpanded: group.entries.length <= 8,
        title: Text(
          group.logId,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Text(subtitle),
        children: [
          for (final entry in group.entries) _DebugEntryTile(entry: entry),
        ],
      ),
    );
  }
}

class _DebugEntryTile extends StatelessWidget {
  const _DebugEntryTile({required this.entry});

  final PipelineDebugEntry entry;

  @override
  Widget build(BuildContext context) {
    final meta = <String>[
      _clock(entry.timestamp),
      if (entry.elapsedLabel.isNotEmpty) entry.elapsedLabel,
      if (entry.attempt != null) 'attempt ${entry.attempt}',
      if (entry.jobId != null) entry.jobId!,
    ].join('  ·  ');
    return ListTile(
      dense: true,
      leading: Icon(_iconFor(entry.stage), size: 20),
      title: Text('${entry.stage.label}: ${entry.event}'),
      subtitle: Text('${entry.message}\n$meta'),
      isThreeLine: true,
    );
  }

  IconData _iconFor(PipelineDebugStage stage) {
    return switch (stage) {
      PipelineDebugStage.recording => Icons.mic_none,
      PipelineDebugStage.transcription => Icons.text_fields,
      PipelineDebugStage.persistence => Icons.save_outlined,
      PipelineDebugStage.queue => Icons.playlist_add,
      PipelineDebugStage.refine => Icons.auto_fix_high,
      PipelineDebugStage.embed => Icons.hub_outlined,
      PipelineDebugStage.canonicalize => Icons.link,
      PipelineDebugStage.memory => Icons.psychology_outlined,
      PipelineDebugStage.action => Icons.check_circle_outline,
      PipelineDebugStage.enrich => Icons.auto_awesome_outlined,
      PipelineDebugStage.summarize => Icons.summarize_outlined,
      PipelineDebugStage.entitySummary => Icons.badge_outlined,
      PipelineDebugStage.digest => Icons.calendar_today_outlined,
      PipelineDebugStage.worker => Icons.engineering_outlined,
    };
  }

  String _clock(DateTime time) {
    final h = time.hour.toString().padLeft(2, '0');
    final m = time.minute.toString().padLeft(2, '0');
    final s = time.second.toString().padLeft(2, '0');
    final ms = time.millisecond.toString().padLeft(3, '0');
    return '$h:$m:$s.$ms';
  }
}
