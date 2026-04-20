import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../capture/models/speech_segment.dart';
import '../../llm/models/cleaned_transcript.dart';
import 'debug_providers.dart';
import 'debug_run_notifier.dart';
import 'widgets/bootstrap_status.dart';
import 'widgets/chunk_tile.dart';
import 'widgets/section_card.dart';
import 'widgets/segment_tile.dart';

/// The only screen this app ships right now: one long scroll that shows
/// every stage of the record → store pipeline live.
class DebugHomeScreen extends ConsumerWidget {
  const DebugHomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final core = ref.watch(coreRuntimeProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('VoxSynth · Debug'),
        centerTitle: false,
      ),
      body: core.when(
        loading: () => const BootstrapStatusView(),
        error: (e, _) => BootstrapStatusView(error: e),
        data: (_) => const _DebugBody(),
      ),
    );
  }
}

class _DebugBody extends ConsumerWidget {
  const _DebugBody();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final run = ref.watch(debugRunProvider);
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        _ControlSection(run: run),
        _CaptureSection(run: run),
        if (run.segments.isNotEmpty) _SegmentsSection(run: run),
        if (run.cleaned != null) _CleanupSection(run: run),
        if (run.chunkPreviews.isNotEmpty) _ChunksSection(run: run),
        if (run.storedLogId != null) _StoreSection(run: run),
        if (run.errorMessage != null && run.phase == DebugRunPhase.error)
          _ErrorSection(message: run.errorMessage!),
      ],
    );
  }
}

// ---------------------------------------------------------------------
// 1. Control
// ---------------------------------------------------------------------

class _ControlSection extends ConsumerWidget {
  const _ControlSection({required this.run});
  final DebugRunState run;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(debugRunProvider.notifier);
    final isRecording = run.phase == DebugRunPhase.recording;
    final isProcessing = run.phase == DebugRunPhase.postProcessing;
    final canReset = run.phase == DebugRunPhase.done ||
        run.phase == DebugRunPhase.error;

    final theme = Theme.of(context);
    return SectionCard(
      title: 'CONTROL',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FilledButton.icon(
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(52),
              backgroundColor: isRecording
                  ? Colors.red.shade600
                  : theme.colorScheme.primary,
            ),
            onPressed: isProcessing
                ? null
                : isRecording
                    ? notifier.stop
                    : canReset
                        ? notifier.reset
                        : notifier.start,
            icon: Icon(
              isRecording
                  ? Icons.stop
                  : canReset
                      ? Icons.refresh
                      : Icons.fiber_manual_record,
            ),
            label: Text(
              isProcessing
                  ? 'Processing…'
                  : isRecording
                      ? 'Stop'
                      : canReset
                          ? 'New recording'
                          : 'Record',
            ),
          ),
          if (isProcessing) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 1.8),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    run.subphase.label,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                _ResidentModelBadge(subphase: run.subphase),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              _subphaseHint(run.subphase),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }

  static String _subphaseHint(DebugSubphase sub) {
    return switch (sub) {
      DebugSubphase.finalizingRecording =>
        'Closing the WAV file and draining the capture buffer.',
      DebugSubphase.loadingAsr =>
        'Mapping ~630 MB of Parakeet weights off disk. First load is slow.',
      DebugSubphase.transcribing =>
        'Running sherpa-onnx transducer beam search on each segment.',
      DebugSubphase.disposingAsr =>
        'Releasing Parakeet before the LLM loads — frees ~1.5 GB.',
      DebugSubphase.loadingLlm =>
        'Mapping ~240 MB of Gemma 3 270M Q4 weights.',
      DebugSubphase.cleaning =>
        'Gemma running: cleanup → topic boundaries → entities → tags.',
      DebugSubphase.disposingLlm =>
        'Releasing Gemma before the embedder loads.',
      DebugSubphase.loadingEmbedder =>
        'Mapping ~450 MB of e5-small safetensors.',
      DebugSubphase.embedding =>
        'Embedding each chunk to a 384-dim L2-normalised vector.',
      DebugSubphase.ingesting =>
        'Writing voice_logs + chunks + ObjectBox vectors transactionally.',
      DebugSubphase.disposingEmbedder =>
        'Releasing the embedder. Peak RAM is back to idle.',
      DebugSubphase.idle => '',
    };
  }
}

class _ResidentModelBadge extends StatelessWidget {
  const _ResidentModelBadge({required this.subphase});
  final DebugSubphase subphase;

  @override
  Widget build(BuildContext context) {
    final (String label, Color color) = switch (subphase) {
      DebugSubphase.loadingAsr ||
      DebugSubphase.transcribing ||
      DebugSubphase.disposingAsr =>
        ('PARAKEET', Colors.blue.shade700),
      DebugSubphase.loadingLlm ||
      DebugSubphase.cleaning ||
      DebugSubphase.disposingLlm =>
        ('GEMMA', Colors.purple.shade700),
      DebugSubphase.loadingEmbedder ||
      DebugSubphase.embedding ||
      DebugSubphase.ingesting ||
      DebugSubphase.disposingEmbedder =>
        ('E5', Colors.teal.shade700),
      _ => ('', Colors.transparent),
    };
    if (label.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontFamily: 'monospace',
          fontSize: 10,
          fontWeight: FontWeight.w700,
          color: color,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------
// 2. Capture status
// ---------------------------------------------------------------------

class _CaptureSection extends StatelessWidget {
  const _CaptureSection({required this.run});
  final DebugRunState run;

  @override
  Widget build(BuildContext context) {
    final totalSegMs = run.segments.fold<int>(
      0,
      (acc, s) => acc + s.durationMs,
    );
    final totalBytes = run.segments.fold<int>(
      0,
      (acc, s) => acc + s.pcmBytes,
    );
    final transcribed = run.segments.where((s) => s.transcript != null).length;

    return SectionCard(
      title: 'CAPTURE',
      trailing: _CaptureStateChip(state: run.captureState),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          KeyValueRow(label: 'phase', value: run.phase.name),
          KeyValueRow(label: 'segments', value: '${run.segments.length}'),
          KeyValueRow(label: 'transcribed', value: '$transcribed'),
          KeyValueRow(
            label: 'total speech',
            value: '$totalSegMs ms '
                '(${(totalSegMs / 1000).toStringAsFixed(2)} s)',
          ),
          KeyValueRow(
            label: 'total PCM',
            value: '$totalBytes B '
                '(${(totalBytes / 1024).toStringAsFixed(1)} KiB)',
          ),
          if (run.recording != null) ...[
            KeyValueRow(
              label: 'recording',
              value: '${run.recording!.durationMs} ms',
            ),
            KeyValueRow(
              label: 'wav',
              value: run.recording!.audioFilePath,
            ),
          ],
        ],
      ),
    );
  }
}

class _CaptureStateChip extends StatelessWidget {
  const _CaptureStateChip({required this.state});
  final CaptureState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (Color bg, Color fg) = switch (state) {
      CaptureState.recording => (Colors.red.shade600, Colors.white),
      CaptureState.paused => (Colors.amber.shade700, Colors.black),
      CaptureState.stopping => (
          theme.colorScheme.secondaryContainer,
          theme.colorScheme.onSecondaryContainer,
        ),
      CaptureState.error => (
          theme.colorScheme.errorContainer,
          theme.colorScheme.onErrorContainer,
        ),
      _ => (
          theme.colorScheme.surfaceContainerHigh,
          theme.colorScheme.onSurfaceVariant,
        ),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        state.name,
        style: theme.textTheme.labelSmall?.copyWith(
          color: fg,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------
// 3. Segments + live transcripts
// ---------------------------------------------------------------------

class _SegmentsSection extends StatelessWidget {
  const _SegmentsSection({required this.run});
  final DebugRunState run;

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      title: 'ASR · TRANSCRIPT',
      child: Column(
        children: [
          for (final s in run.segments) SegmentTile(segment: s),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------
// 4. Cleanup (Gemma)
// ---------------------------------------------------------------------

class _CleanupSection extends StatelessWidget {
  const _CleanupSection({required this.run});
  final DebugRunState run;

  @override
  Widget build(BuildContext context) {
    final cleaned = run.cleaned!;
    return SectionCard(
      title: 'CLEANUP · GEMMA',
      trailing: run.cleanupMs == null
          ? null
          : Text(
              '${run.cleanupMs} ms',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    fontFamily: 'monospace',
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          KeyValueRow(label: 'chunks', value: '${cleaned.chunks.length}'),
          KeyValueRow(label: 'entities', value: '${cleaned.entities.length}'),
          KeyValueRow(
            label: 'cleaned len',
            value: '${cleaned.text.length} chars',
          ),
          if (cleaned.tags.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 4,
              runSpacing: 4,
              children: [
                for (final tag in cleaned.tags)
                  Chip(
                    label: Text('#$tag'),
                    labelStyle: Theme.of(context).textTheme.labelSmall,
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
              ],
            ),
          ],
          const SizedBox(height: 8),
          ExpansionTile(
            title: const Text('Cleaned text'),
            tilePadding: EdgeInsets.zero,
            childrenPadding: const EdgeInsets.symmetric(vertical: 4),
            children: [
              Text(
                cleaned.text,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ],
          ),
          if (cleaned.entities.isNotEmpty)
            ExpansionTile(
              title: Text('Entities (${cleaned.entities.length})'),
              tilePadding: EdgeInsets.zero,
              childrenPadding: const EdgeInsets.symmetric(vertical: 4),
              children: [
                for (final e in cleaned.entities)
                  _EntityRow(entity: e),
              ],
            ),
        ],
      ),
    );
  }
}

class _EntityRow extends StatelessWidget {
  const _EntityRow({required this.entity});
  final Entity entity;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: theme.colorScheme.tertiary.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              entity.kind,
              style: theme.textTheme.labelSmall?.copyWith(
                fontFamily: 'monospace',
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              entity.name
                  + (entity.aliases.isEmpty
                      ? ''
                      : ' · ${entity.aliases.join(", ")}'),
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------
// 5. Chunks + embeddings
// ---------------------------------------------------------------------

class _ChunksSection extends StatelessWidget {
  const _ChunksSection({required this.run});
  final DebugRunState run;

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      title: 'CHUNKS · EMBEDDINGS',
      trailing: run.embedMs == null
          ? null
          : Text(
              '${run.embedMs} ms',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    fontFamily: 'monospace',
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
      child: Column(
        children: [
          for (var i = 0; i < run.chunkPreviews.length; i++)
            ChunkTile(index: i, preview: run.chunkPreviews[i]),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------
// 6. Storage
// ---------------------------------------------------------------------

class _StoreSection extends StatelessWidget {
  const _StoreSection({required this.run});
  final DebugRunState run;

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      title: 'STORE · DRIFT + OBJECTBOX',
      accent: Theme.of(context).colorScheme.primary,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          KeyValueRow(
            label: 'log id',
            value: run.storedLogId?.raw ?? '—',
          ),
          KeyValueRow(
            label: 'chunks',
            value: '${run.storedChunkCount ?? 0}',
          ),
          if (run.recording != null)
            KeyValueRow(
              label: 'wav path',
              value: run.recording!.audioFilePath,
            ),
          const SizedBox(height: 4),
          Text(
            'Wrote voice_logs row + transcript_chunks rows (FTS5 index '
            'auto-populated) + one ObjectBox HNSW vector per chunk.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------
// Error banner
// ---------------------------------------------------------------------

class _ErrorSection extends StatelessWidget {
  const _ErrorSection({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      title: 'ERROR',
      accent: Theme.of(context).colorScheme.error,
      child: Text(
        message,
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.error,
            ),
      ),
    );
  }
}
