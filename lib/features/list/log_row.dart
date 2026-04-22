import 'package:flutter/material.dart';

import '../../core/db/processing_state.dart';
import '../../core/db/repositories/voice_log_repository.dart';

/// One row in the home list. Shows date, duration, first line of the
/// transcript, and a processing-state badge.
class LogRow extends StatelessWidget {
  const LogRow({super.key, required this.log, required this.onTap});

  final VoiceLogView log;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final subtitle = _firstLine(log.displayText);
    return ListTile(
      onTap: onTap,
      title: Text(
        subtitle.isEmpty ? '(no transcript)' : subtitle,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(_metaLine(log)),
      trailing: _badge(log.processingState),
    );
  }

  String _firstLine(String text) {
    final idx = text.indexOf('\n');
    final line = idx >= 0 ? text.substring(0, idx) : text;
    return line.trim();
  }

  String _metaLine(VoiceLogView log) {
    final when = _shortDate(log.createdAt);
    final dur = (log.durationMs / 1000).toStringAsFixed(1);
    return '$when  ·  ${dur}s';
  }

  String _shortDate(DateTime when) {
    final now = DateTime.now();
    final same =
        when.year == now.year && when.month == now.month && when.day == now.day;
    final h = when.hour.toString().padLeft(2, '0');
    final m = when.minute.toString().padLeft(2, '0');
    if (same) return '$h:$m';
    return '${when.month}/${when.day}  $h:$m';
  }

  Widget? _badge(ProcessingState state) {
    switch (state) {
      case ProcessingState.recorded:
        return const _Shimmer(label: 'refining');
      case ProcessingState.refined:
        return const _Shimmer(label: 'embedding');
      case ProcessingState.embedded:
        return null;
      case ProcessingState.failed:
        return const Icon(Icons.error_outline, color: Colors.redAccent);
    }
  }
}

class _Shimmer extends StatelessWidget {
  const _Shimmer({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      style: TextStyle(
        fontSize: 11,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
  }
}
