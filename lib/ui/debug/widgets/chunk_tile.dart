import 'package:flutter/material.dart';

import '../debug_run_notifier.dart';
import 'section_card.dart';

/// One topic chunk plus the first handful of values from its 384-dim e5
/// embedding. The embedding preview is what makes this debug-useful —
/// eyeballing that the vector is non-zero and different per chunk
/// confirms e5 actually ran.
class ChunkTile extends StatelessWidget {
  const ChunkTile({
    super.key,
    required this.index,
    required this.preview,
  });

  final int index;
  final DebugChunkPreview preview;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final chunk = preview.chunk;
    final embedding = preview.embedding;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
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
                    color:
                        theme.colorScheme.secondary.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    '[C${index + 1}]',
                    style: theme.textTheme.labelSmall?.copyWith(
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    chunk.topicHint,
                    style: theme.textTheme.labelMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(
                  '${chunk.wordCount}w',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontFamily: 'monospace',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              chunk.text,
              style: theme.textTheme.bodyMedium,
            ),
            if (chunk.entityRefs.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 4,
                runSpacing: 4,
                children: [
                  for (final name in chunk.entityRefs)
                    Chip(
                      label: Text(name),
                      labelStyle: theme.textTheme.labelSmall,
                      visualDensity: VisualDensity.compact,
                      materialTapTargetSize:
                          MaterialTapTargetSize.shrinkWrap,
                    ),
                ],
              ),
            ],
            const SizedBox(height: 8),
            if (embedding == null)
              Row(
                children: [
                  const SizedBox(
                    width: 10,
                    height: 10,
                    child: CircularProgressIndicator(strokeWidth: 1.2),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'embedding…',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              )
            else
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  KeyValueRow(
                    label: 'dim',
                    value: '${embedding.length}',
                  ),
                  KeyValueRow(
                    label: 'norm',
                    value: _norm(embedding).toStringAsFixed(4),
                  ),
                  KeyValueRow(
                    label: 'first 8',
                    value: _formatPreview(embedding, 8),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  static double _norm(List<double> v) {
    var sumSq = 0.0;
    for (final x in v) {
      sumSq += x * x;
    }
    var guess = sumSq;
    for (var i = 0; i < 16; i++) {
      guess = 0.5 * (guess + sumSq / (guess == 0 ? 1 : guess));
    }
    return guess;
  }

  static String _formatPreview(List<double> v, int n) {
    final count = n < v.length ? n : v.length;
    final buf = StringBuffer('[');
    for (var i = 0; i < count; i++) {
      if (i > 0) buf.write(', ');
      buf.write(v[i].toStringAsFixed(3));
    }
    if (v.length > count) buf.write(', …');
    buf.write(']');
    return buf.toString();
  }
}
