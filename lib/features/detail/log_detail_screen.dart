import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../app_theme.dart';
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
    ProcessingState.recorded => 'Refining transcript and extracting entities...',
    ProcessingState.refined => 'Embedding transcript for semantic search...',
    ProcessingState.embedded => 'Ready for semantic/entity search',
    ProcessingState.failed => 'Processing failed',
  };
}

/// Redesigned premium retro-minimalist detail screen for a single voice log.
///
/// Features hardware corner studs, an elegant white container card that aggregates the tape
/// waveform, flanking durations, dedicated square media skip/play controls, a custom volume slider,
/// horizontal HSL tags, and the flat retro action buttons (Delete/Share/Rename) at the base.
class LogDetailScreen extends ConsumerStatefulWidget {
  const LogDetailScreen({
    super.key,
    required this.logId,
    this.initialSeekMs,
    this.highlightStartMs,
    this.highlightEndMs,
  });

  final String logId;
  final int? initialSeekMs;
  final int? highlightStartMs;
  final int? highlightEndMs;

  @override
  ConsumerState<LogDetailScreen> createState() => _LogDetailScreenState();
}

class _LogDetailScreenState extends ConsumerState<LogDetailScreen> {
  final AudioPlayerController _audio = AudioPlayerController();
  Future<WaveformPeaks>? _peaksFuture;
  String? _audioPathLoaded;
  bool _initialSeekApplied = false;

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
      backgroundColor: VoxAppColors.canvas,
      body: SafeArea(
        child: Stack(
          children: [
            // Four Corner Screws/Studs
            const Positioned(left: 10, top: 10, child: _SilverStud()),
            const Positioned(right: 10, top: 10, child: _SilverStud()),
            const Positioned(left: 10, bottom: 10, child: _SilverStud()),
            const Positioned(right: 10, bottom: 10, child: _SilverStud()),

            logAsync.when(
              data: (log) {
                if (log == null) {
                  return const Center(child: Text('Voice log not found', style: TextStyle(fontFamily: 'monospace')));
                }
                final absoluteAudio = _resolveAudio(log);
                if (File(absoluteAudio).existsSync()) {
                  _peaksFuture ??= loadWaveformPeaks(absoluteAudio);
                  _ensureAudioLoaded(absoluteAudio);
                }
                final fallback = log.cleanedText ?? log.rawTranscript;
                final mentions = mentionsAsync.value ?? const [];
                final segments = segmentsAsync.value ?? const [];

                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 12.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Header Row
                      const SizedBox(height: 12),
                      _buildHeader(context, log),
                      const SizedBox(height: 8),
                      const _DashedDivider(),
                      const SizedBox(height: 16),

                      // Symmetrical Playback Controller Card
                      _PlaybackCard(
                        audio: _audio,
                        peaksFuture: _peaksFuture,
                      ),
                      const SizedBox(height: 16),

                      // Optional Processing Info Status
                      if (log.processingState != ProcessingState.embedded) ...[
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: VoxAppColors.outline),
                          ),
                          child: Row(
                            children: [
                              const SizedBox(
                                width: 12,
                                height: 12,
                                child: CircularProgressIndicator(strokeWidth: 2, color: VoxAppColors.accent),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  _statusText(log.processingState),
                                  style: const TextStyle(
                                    fontSize: 11,
                                    fontStyle: FontStyle.italic,
                                    color: VoxAppColors.muted,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 12),
                      ],

                      // Log summary & tagging chip container
                      if (mentions.isNotEmpty) ...[
                        EntityChips(mentions: mentions),
                        const SizedBox(height: 12),
                      ],
                      
                      LogSummaryPanel(logId: widget.logId),

                      // Expanded Transcript Card
                      Expanded(
                        child: Container(
                          margin: const EdgeInsets.only(top: 8, bottom: 16),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: VoxAppColors.outline),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.03),
                                blurRadius: 6,
                                offset: const Offset(0, 3),
                              ),
                            ],
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              // Transcript Header Label
                              Padding(
                                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                                child: Row(
                                  children: [
                                    const Icon(Icons.description_outlined, size: 14, color: VoxAppColors.accent),
                                    const SizedBox(width: 6),
                                    Text(
                                      'JOURNAL TRANSCRIPT',
                                      style: TextStyle(
                                        fontFamily: 'monospace',
                                        fontSize: 11,
                                        fontWeight: FontWeight.w900,
                                        letterSpacing: 1.5,
                                        color: VoxAppColors.ink.withValues(alpha: 0.8),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const _DashedDivider(),
                              
                              // Main Transcript scrollable zone
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
                            ],
                          ),
                        ),
                      ),

                      // Failed error view warning
                      if (log.processingState == ProcessingState.failed) ...[
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Text(
                            'Refinement failed: ${log.errorMessage ?? "unknown"}',
                            style: const TextStyle(color: VoxAppColors.error, fontSize: 12),
                          ),
                        ),
                        const SizedBox(height: 8),
                      ],

                      // base Action buttons (Delete, Share, Rename)
                      _buildBottomActions(context, log),
                      const SizedBox(height: 8),
                    ],
                  ),
                );
              },
              loading: () => const Center(child: CircularProgressIndicator(color: VoxAppColors.accent)),
              error: (e, _) => Center(child: Text('Error: $e', style: const TextStyle(fontFamily: 'monospace'))),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context, VoiceLogView log) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        // Chevron Left Back button
        GestureDetector(
          onTap: () => Navigator.of(context).pop(),
          child: Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: VoxAppColors.outline, width: 1),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.03),
                  blurRadius: 3,
                  offset: const Offset(0, 1.5),
                ),
              ],
            ),
            child: const Icon(
              Icons.chevron_left_rounded,
              color: VoxAppColors.ink,
              size: 22,
            ),
          ),
        ),

        // Uppercase, monospaced title
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0),
            child: Text(
              _firstLine(log.displayTitle).toUpperCase(),
              textAlign: TextAlign.center,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 13,
                fontWeight: FontWeight.w900,
                letterSpacing: 1.2,
                color: VoxAppColors.ink,
              ),
            ),
          ),
        ),

        // Settings / Options Popup Button
        Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: VoxAppColors.outline, width: 1),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.03),
                blurRadius: 3,
                offset: const Offset(0, 1.5),
              ),
            ],
          ),
          child: Theme(
            data: Theme.of(context).copyWith(
              cardColor: Colors.white,
              popupMenuTheme: const PopupMenuThemeData(
                color: Colors.white,
                elevation: 3,
              ),
            ),
            child: PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert_rounded, color: VoxAppColors.ink, size: 20),
              padding: EdgeInsets.zero,
              onSelected: _onAction,
              itemBuilder: (_) => [
                if (log.processingState == ProcessingState.failed)
                  const PopupMenuItem(
                    value: 'retry',
                    child: Text('Retry refinement', style: TextStyle(fontFamily: 'monospace', fontSize: 13)),
                  ),
                const PopupMenuItem(
                  value: 'delete',
                  child: Text('Delete Log', style: TextStyle(fontFamily: 'monospace', fontSize: 13, color: VoxAppColors.accent, fontWeight: FontWeight.bold)),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildBottomActions(BuildContext context, VoiceLogView log) {
    return Row(
      children: [
        // Sizable Red Delete Button
        Expanded(
          child: GestureDetector(
            onTap: () async {
              final confirm = await _showDeleteConfirmDialog(context);
              if (confirm == true) {
                await _onAction('delete');
              }
            },
            child: Container(
              height: 48,
              decoration: BoxDecoration(
                color: VoxAppColors.accent,
                borderRadius: BorderRadius.circular(8),
                boxShadow: [
                  BoxShadow(
                    color: VoxAppColors.accent.withValues(alpha: 0.15),
                    blurRadius: 4,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: const Center(
                child: Text(
                  'DELETE',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontFamily: 'monospace',
                    fontSize: 13,
                    letterSpacing: 1.0,
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 10),

        // Sizable Share Button
        Expanded(
          child: GestureDetector(
            onTap: () {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Raw transcript copied to clipboard!', style: TextStyle(fontFamily: 'monospace')),
                  duration: Duration(seconds: 2),
                ),
              );
            },
            child: Container(
              height: 48,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: VoxAppColors.outline, width: 1.2),
              ),
              child: const Center(
                child: Text(
                  'SHARE',
                  style: TextStyle(
                    color: VoxAppColors.ink,
                    fontWeight: FontWeight.bold,
                    fontFamily: 'monospace',
                    fontSize: 13,
                    letterSpacing: 1.0,
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 10),

        // Sizable Rename Button
        Expanded(
          child: GestureDetector(
            onTap: () => _onEditTitle(log),
            child: Container(
              height: 48,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: VoxAppColors.outline, width: 1.2),
              ),
              child: const Center(
                child: Text(
                  'RENAME',
                  style: TextStyle(
                    color: VoxAppColors.ink,
                    fontWeight: FontWeight.bold,
                    fontFamily: 'monospace',
                    fontSize: 13,
                    letterSpacing: 1.0,
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Future<bool?> _showDeleteConfirmDialog(BuildContext context) {
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: VoxAppColors.outline),
        ),
        title: const Text(
          'DELETE VOICE LOG?',
          style: TextStyle(fontFamily: 'monospace', fontWeight: FontWeight.bold, fontSize: 16),
        ),
        content: const Text(
          'Are you sure you want to permanently delete this voice log? This cannot be undone.',
          style: TextStyle(fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('CANCEL', style: TextStyle(color: VoxAppColors.muted, fontFamily: 'monospace')),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('DELETE', style: TextStyle(color: VoxAppColors.accent, fontWeight: FontWeight.bold, fontFamily: 'monospace')),
          ),
        ],
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

/// Custom Playback Controller Card that groups the Scrubbing Waveform, Elapsed/Remaining Timer 
/// labels, dedicated backward/forward Skip square buttons, Charcoal Play square button, and customized Volume slider.
class _PlaybackCard extends StatefulWidget {
  const _PlaybackCard({
    required this.audio,
    required this.peaksFuture,
  });

  final AudioPlayerController audio;
  final Future<WaveformPeaks>? peaksFuture;

  @override
  State<_PlaybackCard> createState() => _PlaybackCardState();
}

class _PlaybackCardState extends State<_PlaybackCard> {
  StreamSubscription<Duration>? _posSub;
  StreamSubscription<bool>? _playSub;
  Duration _position = Duration.zero;
  bool _playing = false;
  double _volume = 1.0;

  @override
  void initState() {
    super.initState();
    _posSub = widget.audio.positionStream.listen((p) {
      if (!mounted) return;
      setState(() => _position = p);
    });
    _playSub = widget.audio.playingStream.listen((p) {
      if (!mounted) return;
      setState(() => _playing = p);
    });
    _volume = widget.audio.volume;
  }

  @override
  void dispose() {
    _posSub?.cancel();
    _playSub?.cancel();
    super.dispose();
  }

  String _formatMs(int ms) {
    final totalSec = ms ~/ 1000;
    final min = totalSec ~/ 60;
    final sec = totalSec % 60;
    return '${min.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final totalDuration = widget.audio.duration ?? Duration.zero;
    final totalMs = totalDuration.inMilliseconds;
    final currentMs = _position.inMilliseconds;

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: VoxAppColors.outline, width: 1.2),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 8,
            offset: const Offset(0, 3.5),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Waveform Scrubber
          SizedBox(
            height: 52,
            child: widget.peaksFuture == null
                ? const SizedBox.shrink()
                : FutureBuilder<WaveformPeaks>(
                    future: widget.peaksFuture,
                    builder: (context, snapshot) {
                      final peaks = snapshot.data ?? const WaveformPeaks(peaks: [], totalMs: 0);
                      return WaveformScrubber(
                        peaks: peaks,
                        controller: widget.audio,
                        height: 52,
                      );
                    },
                  ),
          ),
          const SizedBox(height: 8),

          // Duration Labels Row
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                _formatMs(currentMs),
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: VoxAppColors.muted,
                ),
              ),
              Text(
                _formatMs(totalMs),
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: VoxAppColors.muted,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          const _DashedDivider(),
          const SizedBox(height: 16),

          // Square media controls
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // 10s Rewind Square Button
              GestureDetector(
                onTap: () {
                  final newPos = _position - const Duration(seconds: 10);
                  widget.audio.seek(newPos < Duration.zero ? Duration.zero : newPos);
                },
                child: Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: VoxAppColors.outline, width: 1.2),
                  ),
                  child: const Icon(
                    Icons.replay_10_rounded,
                    color: VoxAppColors.ink,
                    size: 20,
                  ),
                ),
              ),
              const SizedBox(width: 24),

              // Square Play/Pause Charcoal Center Button
              GestureDetector(
                onTap: () => _playing ? widget.audio.pause() : widget.audio.play(),
                child: Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(
                    color: VoxAppColors.primary,
                    borderRadius: BorderRadius.circular(10),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.15),
                        blurRadius: 5,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Icon(
                    _playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                    color: Colors.white,
                    size: 26,
                  ),
                ),
              ),
              const SizedBox(width: 24),

              // 10s Forward Skip Square Button
              GestureDetector(
                onTap: () {
                  final total = widget.audio.duration ?? Duration.zero;
                  final newPos = _position + const Duration(seconds: 10);
                  widget.audio.seek(newPos > total ? total : newPos);
                },
                child: Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: VoxAppColors.outline, width: 1.2),
                  ),
                  child: const Icon(
                    Icons.forward_10_rounded,
                    color: VoxAppColors.ink,
                    size: 20,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // Custom Volume Slider Row
          Row(
            children: [
              const Icon(Icons.volume_up_outlined, size: 18, color: VoxAppColors.muted),
              const SizedBox(width: 6),
              Expanded(
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 2.0,
                    thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5.0),
                    overlayShape: const RoundSliderOverlayShape(overlayRadius: 10.0),
                    activeTrackColor: VoxAppColors.primary,
                    inactiveTrackColor: VoxAppColors.outline,
                    thumbColor: VoxAppColors.primary,
                  ),
                  child: Slider(
                    value: _volume,
                    onChanged: (val) {
                      setState(() {
                        _volume = val;
                        widget.audio.setVolume(val);
                      });
                    },
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

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
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: VoxAppColors.outline),
      ),
      title: const Text(
        'RENAME VOICE LOG',
        style: TextStyle(fontFamily: 'monospace', fontWeight: FontWeight.bold, fontSize: 16),
      ),
      content: TextField(
        controller: _controller,
        autofocus: true,
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _submit(),
        style: const TextStyle(fontSize: 14),
        decoration: const InputDecoration(
          hintText: 'Enter title...',
          hintStyle: TextStyle(color: VoxAppColors.muted, fontSize: 13),
          enabledBorder: UnderlineInputBorder(
            borderSide: BorderSide(color: VoxAppColors.outline, width: 1.5),
          ),
          focusedBorder: UnderlineInputBorder(
            borderSide: BorderSide(color: VoxAppColors.primary, width: 1.5),
          ),
        ),
        maxLength: 120,
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('CANCEL', style: TextStyle(color: VoxAppColors.muted, fontFamily: 'monospace')),
        ),
        TextButton(
          onPressed: _submit,
          child: const Text('SAVE', style: TextStyle(color: VoxAppColors.primary, fontWeight: FontWeight.bold, fontFamily: 'monospace')),
        ),
      ],
    );
  }
}

class _SilverStud extends StatelessWidget {
  const _SilverStud();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(
        color: const Color(0xFFE0E0E0),
        shape: BoxShape.circle,
        border: Border.all(color: const Color(0xFFB0B0B0), width: 0.8),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0A000000),
            blurRadius: 0.8,
            offset: Offset(0, 0.8),
          ),
        ],
      ),
      child: Center(
        child: Container(
          width: 2.5,
          height: 2.5,
          decoration: const BoxDecoration(
            color: Color(0xFF888888),
            shape: BoxShape.circle,
          ),
        ),
      ),
    );
  }
}

class _DashedDivider extends StatelessWidget {
  const _DashedDivider();

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final boxWidth = constraints.constrainWidth();
        const dashWidth = 3.0;
        const dashSpace = 3.0;
        final dashCount = (boxWidth / (dashWidth + dashSpace)).floor();
        return Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: List.generate(dashCount, (_) {
            return SizedBox(
              width: dashWidth,
              height: 1,
              child: DecoratedBox(
                decoration: BoxDecoration(color: VoxAppColors.outline),
              ),
            );
          }),
        );
      },
    );
  }
}
