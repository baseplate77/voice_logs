import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/pipeline_debug.dart';
import '../../core/pipeline_debug_provider.dart';

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
      body: entries.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'No pipeline events yet. Record a log to see timings.',
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : ListView.builder(
              itemCount: groups.length,
              itemBuilder: (context, index) {
                final group = groups[index];
                return _LogDebugGroup(group: group);
              },
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
      PipelineDebugStage.enrich => Icons.auto_awesome_outlined,
      PipelineDebugStage.summarize => Icons.summarize_outlined,
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
