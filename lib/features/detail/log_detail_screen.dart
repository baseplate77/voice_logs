import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../core/db/job_state.dart';
import '../../core/db/processing_state.dart';
import '../../core/db/providers.dart';
import '../../core/db/repositories/voice_log_repository.dart';
import '../../core/worker/providers.dart';
import 'audio_player_controller.dart';
import 'entity_chips.dart';
import 'log_summary_panel.dart';
import 'markdown_transcript_view.dart';
import 'transcript_player_view.dart';
import 'waveform_scrubber.dart';

String _firstLine(String text) {
  final idx = text.indexOf('\n');
  final line = idx >= 0 ? text.substring(0, idx) : text;
  return line.trim();
}

String _statusText(ProcessingState state) {
  return switch (state) {
    ProcessingState.recorded => 'Refining transcript and extracting entities…',
    ProcessingState.refined => 'Embedding transcript for semantic search…',
    ProcessingState.embedded => 'Ready for semantic/entity search',
    ProcessingState.failed => 'Processing failed',
  };
}

/// Detail view for a single voice log — synced audio playback, tappable
/// transcript, entity chips, delete/retry actions.
class LogDetailScreen extends ConsumerStatefulWidget {
  const LogDetailScreen({
    super.key,
    required this.logId,
    this.initialSeekMs,
    this.highlightStartMs,
    this.highlightEndMs,
  });

  final String logId;

  /// Optional initial playback position in ms. When provided, the player
  /// seeks here on load and starts playback. Used by Ask citations to
  /// jump to the moment a source was quoted from.
  final int? initialSeekMs;

  /// Inclusive start of an optional source-span highlight. Words in the
  /// range receive a sustained accent in the transcript view.
  final int? highlightStartMs;

  /// Inclusive end of the optional source-span highlight.
  final int? highlightEndMs;

  @override
  ConsumerState<LogDetailScreen> createState() => _LogDetailScreenState();
}

class _LogDetailScreenState extends ConsumerState<LogDetailScreen> {
  final AudioPlayerController _audio = AudioPlayerController();
  Future<WaveformPeaks>? _peaksFuture;
  String? _audioPathLoaded;
  bool _playing = false;
  bool _initialSeekApplied = false;

  @override
  void initState() {
    super.initState();
    _audio.playingStream.listen((p) {
      if (!mounted) return;
      setState(() => _playing = p);
    });
  }

  @override
  void dispose() {
    _audio.dispose();
    super.dispose();
  }

  Future<void> _ensureAudioLoaded(String absolutePath) async {
    if (_audioPathLoaded == absolutePath) return;
    _audioPathLoaded = absolutePath;
    final err = await _audio.loadFile(absolutePath);
    if (err != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
      return;
    }
    final seekTo = widget.initialSeekMs;
    if (seekTo != null && !_initialSeekApplied) {
      _initialSeekApplied = true;
      await _audio.seek(Duration(milliseconds: seekTo));
      await _audio.play();
    }
  }

  String _resolveAudio(VoiceLogView log) {
    final docs = ref.read(appDocumentsPathProvider);
    return p.isAbsolute(log.audioPath)
        ? log.audioPath
        : p.join(docs, log.audioPath);
  }

  @override
  Widget build(BuildContext context) {
    final logAsync = ref.watch(voiceLogByIdProvider(widget.logId));
    final mentionsAsync = ref.watch(voiceLogMentionsProvider(widget.logId));
    final segmentsAsync = ref.watch(
      transcriptSegmentsForLogProvider(widget.logId),
    );

    return Scaffold(
      appBar: AppBar(
        title: logAsync.maybeWhen(
          data: (log) => _AppBarTitle(log: log),
          orElse: () => const Text('Log'),
        ),
        actions: [
          logAsync.maybeWhen(
            data: (log) => log == null
                ? const SizedBox.shrink()
                : IconButton(
                    tooltip: 'Edit title',
                    icon: const Icon(Icons.edit_outlined),
                    onPressed: () => _onEditTitle(log),
                  ),
            orElse: () => const SizedBox.shrink(),
          ),
          logAsync.maybeWhen(
            data: (log) => log == null
                ? const SizedBox.shrink()
                : PopupMenuButton<String>(
                    onSelected: _onAction,
                    itemBuilder: (_) => [
                      if (log.processingState == ProcessingState.failed)
                        const PopupMenuItem(
                          value: 'retry',
                          child: Text('Retry refinement'),
                        ),
                      const PopupMenuItem(
                        value: 'delete',
                        child: Text('Delete'),
                      ),
                    ],
                  ),
            orElse: () => const SizedBox.shrink(),
          ),
        ],
      ),
      body: logAsync.when(
        data: (log) {
          if (log == null) {
            return const Center(child: Text('Log not found'));
          }
          final absoluteAudio = _resolveAudio(log);
          if (File(absoluteAudio).existsSync()) {
            _peaksFuture ??= loadWaveformPeaks(absoluteAudio);
            _ensureAudioLoaded(absoluteAudio);
          }
          final fallback = log.cleanedText ?? log.rawTranscript;
          final mentions = mentionsAsync.value ?? const [];
          final segments = segmentsAsync.value ?? const [];

          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 8),
              LogSummaryPanel(logId: widget.logId),
              EntityChips(mentions: mentions),
              const SizedBox(height: 8),
              _PlaybackBar(
                audio: _audio,
                playing: _playing,
                peaksFuture: _peaksFuture,
              ),
              if (log.processingState != ProcessingState.embedded)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 4,
                  ),
                  child: Text(
                    _statusText(log.processingState),
                    style: const TextStyle(fontStyle: FontStyle.italic),
                  ),
                ),
              Expanded(
                child: segments.isEmpty
                    ? SingleChildScrollView(
                        padding: const EdgeInsets.all(16),
                        child: MarkdownTranscriptView(
                          text: fallback,
                          mentions: mentions,
                        ),
                      )
                    : TranscriptPlayerView(
                        segments: segments,
                        controller: _audio,
                        fallbackText: fallback,
                        focusedStartMs: widget.highlightStartMs,
                        focusedEndMs: widget.highlightEndMs,
                      ),
              ),
              if (log.processingState == ProcessingState.failed)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    'Refinement failed: ${log.errorMessage ?? "unknown"}',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
            ],
          );
        },
        loading: () =>
            const Center(child: CircularProgressIndicator.adaptive()),
        error: (e, _) => Center(child: Text('Error: $e')),
      ),
    );
  }

  Future<void> _onAction(String action) async {
    switch (action) {
      case 'retry':
        final queue = ref.read(jobQueueProvider);
        await queue.enqueue(logId: widget.logId, type: JobType.refine);
      case 'delete':
        final repo = ref.read(voiceLogRepositoryProvider);
        final res = await repo.delete(widget.logId);
        if (!mounted) return;
        if (res.isOk) Navigator.of(context).pop();
    }
  }

  Future<void> _onEditTitle(VoiceLogView log) async {
    final initial = log.title?.trim() ?? '';
    final result = await showDialog<String?>(
      context: context,
      builder: (_) => _EditTitleDialog(initialTitle: initial),
    );
    if (!mounted) return;
    if (result == null) return;
    final repo = ref.read(voiceLogRepositoryProvider);
    final res = await repo.updateTitle(
      id: widget.logId,
      title: result.isEmpty ? null : result,
    );
    if (!mounted) return;
    if (res.isErr) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Could not update title')));
    }
  }
}

/// App bar title for the detail screen. While refine is still running and
/// no title has been generated yet, renders a shimmer skeleton instead of
/// the raw transcript fallback so the title is clearly "in progress".
class _AppBarTitle extends StatelessWidget {
  const _AppBarTitle({required this.log});

  final VoiceLogView? log;

  @override
  Widget build(BuildContext context) {
    final l = log;
    if (l == null) return const Text('Log');
    final title = l.title?.trim();
    final hasTitle = title != null && title.isNotEmpty;
    if (!hasTitle && l.processingState == ProcessingState.recorded) {
      return const _AppBarTitleSkeleton();
    }
    return Text(_firstLine(l.displayTitle), overflow: TextOverflow.ellipsis);
  }
}

class _AppBarTitleSkeleton extends StatefulWidget {
  const _AppBarTitleSkeleton();

  @override
  State<_AppBarTitleSkeleton> createState() => _AppBarTitleSkeletonState();
}

class _AppBarTitleSkeletonState extends State<_AppBarTitleSkeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final base = scheme.onSurface.withValues(alpha: 0.10);
    final highlight = scheme.onSurface.withValues(alpha: 0.22);
    return AnimatedBuilder(
      animation: _pulse,
      builder: (_, _) {
        final color = Color.lerp(base, highlight, _pulse.value)!;
        return Align(
          alignment: Alignment.centerLeft,
          child: Container(
            width: 160,
            height: 14,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(4),
            ),
          ),
        );
      },
    );
  }
}

/// Modal dialog to rename a log. Submits the trimmed text (empty clears
/// the title and falls back to the auto-generated [VoiceLogView.displayTitle]).
class _EditTitleDialog extends StatefulWidget {
  const _EditTitleDialog({required this.initialTitle});

  final String initialTitle;

  @override
  State<_EditTitleDialog> createState() => _EditTitleDialogState();
}

class _EditTitleDialogState extends State<_EditTitleDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialTitle);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    Navigator.of(context).pop(_controller.text.trim());
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Edit title'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _submit(),
        decoration: const InputDecoration(
          hintText: 'Title',
          border: OutlineInputBorder(),
        ),
        maxLength: 120,
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Save')),
      ],
    );
  }
}

class _PlaybackBar extends StatelessWidget {
  const _PlaybackBar({
    required this.audio,
    required this.playing,
    required this.peaksFuture,
  });

  final AudioPlayerController audio;
  final bool playing;
  final Future<WaveformPeaks>? peaksFuture;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        children: [
          IconButton(
            icon: Icon(playing ? Icons.pause_circle : Icons.play_circle),
            iconSize: 36,
            onPressed: () => playing ? audio.pause() : audio.play(),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: peaksFuture == null
                ? const SizedBox(height: 48)
                : FutureBuilder<WaveformPeaks>(
                    future: peaksFuture,
                    builder: (context, snapshot) {
                      final peaks =
                          snapshot.data ??
                          const WaveformPeaks(peaks: [], totalMs: 0);
                      return WaveformScrubber(
                        peaks: peaks,
                        controller: audio,
                        height: 48,
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
