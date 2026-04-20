import 'package:flutter/material.dart';

import '../debug_run_notifier.dart';
import 'section_card.dart';

/// One captured segment: timing, size, latency, and the transcript once
/// Parakeet returns. Pending while the transcribe call is in flight;
/// switches to red with the error text if it fails.
class SegmentTile extends StatelessWidget {
  const SegmentTile({super.key, required this.segment});

  final DebugSegment segment;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasResult = segment.transcript != null || segment.errorMessage != null;
    final isError = segment.errorMessage != null;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: isError
              ? theme.colorScheme.errorContainer.withValues(alpha: 0.4)
              : theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    '#${segment.id}',
                    style: theme.textTheme.labelSmall?.copyWith(
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  _fmtRange(segment.startMs, segment.endMs),
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontFamily: 'monospace',
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const Spacer(),
                if (!hasResult)
                  const SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(strokeWidth: 1.5),
                  )
                else
                  Text(
                    '${segment.transcribeMs ?? "?"} ms',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontFamily: 'monospace',
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            if (isError)
              Text(
                segment.errorMessage!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              )
            else if (segment.transcript != null)
              Text(
                segment.transcript!.text.isEmpty
                    ? '(empty — likely silence)'
                    : segment.transcript!.text,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontStyle: segment.transcript!.text.isEmpty
                      ? FontStyle.italic
                      : FontStyle.normal,
                  color: segment.transcript!.text.isEmpty
                      ? theme.colorScheme.onSurfaceVariant
                      : null,
                ),
              )
            else
              Text(
                'transcribing…',
                style: theme.textTheme.bodySmall?.copyWith(
                  fontStyle: FontStyle.italic,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            const SizedBox(height: 4),
            KeyValueRow(
              label: 'duration',
              value: '${segment.durationMs} ms',
            ),
            KeyValueRow(
              label: 'PCM',
              value: '${segment.pcmBytes} B '
                  '(${(segment.pcmBytes / 1024).toStringAsFixed(1)} KiB)',
            ),
          ],
        ),
      ),
    );
  }

  static String _fmtRange(int startMs, int endMs) {
    return '${_fmtMs(startMs)}–${_fmtMs(endMs)}';
  }

  static String _fmtMs(int ms) {
    final seconds = ms ~/ 1000;
    final millis = ms % 1000;
    return '$seconds.${millis.toString().padLeft(3, '0')}s';
  }
}
