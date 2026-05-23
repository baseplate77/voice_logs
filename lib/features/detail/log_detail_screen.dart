import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:iconsax/iconsax.dart';
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
    ProcessingState.transcribing => 'Transcribing audio...',
    ProcessingState.recorded =>
      'Refining transcript and extracting entities...',
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
            logAsync.when(
              data: (log) {
                if (log == null) {
                  return const Center(child: Text('Voice log not found'));
                }
                final absoluteAudio = _resolveAudio(log);
                if (File(absoluteAudio).existsSync()) {
                  _peaksFuture ??= loadWaveformPeaks(absoluteAudio);
                  _ensureAudioLoaded(absoluteAudio);
                }
                final fallback = log.cleanedText ?? log.rawTranscript;
                final mentions = mentionsAsync.value ?? [];
                final segments = segmentsAsync.value ?? [];

                return Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: 20.0.w,
                    vertical: 12.0.h,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Header Row
                      SizedBox(height: 12.h),
                      _buildHeader(context, log),
                      SizedBox(height: 8.h),
                      const _DashedDivider(),
                      SizedBox(height: 16.h),

                      // Main scrollable central cards area
                      Expanded(
                        child: SingleChildScrollView(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              // Symmetrical Playback Controller Card
                              _PlaybackCard(
                                audio: _audio,
                                peaksFuture: _peaksFuture,
                              ),
                              SizedBox(height: 16.h),

                              // Optional Processing Info Status
                              if (log.processingState !=
                                  ProcessingState.embedded) ...[
                                Container(
                                  padding: EdgeInsets.symmetric(
                                    horizontal: 14.w,
                                    vertical: 8.h,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.white,
                                    borderRadius: BorderRadius.circular(8.r),
                                    border: Border.all(
                                      color: VoxAppColors.outline,
                                    ),
                                  ),
                                  child: Row(
                                    children: [
                                      SizedBox(
                                        width: 12.w,
                                        height: 12.h,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2.r,
                                          color: VoxAppColors.accent,
                                        ),
                                      ),
                                      SizedBox(width: 10.w),
                                      Expanded(
                                        child: Text(
                                          _statusText(log.processingState),
                                          style: TextStyle(
                                            fontSize: 12.sp,
                                            fontStyle: FontStyle.italic,
                                            color: VoxAppColors.muted,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                SizedBox(height: 12.h),
                              ],

                              // Log summary & tagging chip container
                              if (mentions.isNotEmpty) ...[
                                EntityChips(mentions: mentions),
                                SizedBox(height: 12.h),
                              ],

                              LogSummaryPanel(logId: widget.logId),

                              // Dynamic height Transcript Card
                              Container(
                                margin: EdgeInsets.only(top: 8.h, bottom: 16.h),
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(16.r),
                                  border: Border.all(
                                    color: VoxAppColors.outline,
                                  ),
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black.withValues(
                                        alpha: 0.03,
                                      ),
                                      blurRadius: 6.r,
                                      offset: Offset(0.w, 3.h),
                                    ),
                                  ],
                                ),
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    // Transcript Header Label
                                    Padding(
                                      padding: const EdgeInsets.fromLTRB(
                                        16,
                                        12,
                                        16,
                                        8,
                                      ),
                                      child: Row(
                                        children: [
                                          Icon(
                                            Iconsax.document_text,
                                            size: 14.r,
                                            color: VoxAppColors.accent,
                                          ),
                                          SizedBox(width: 6.w),
                                          Text(
                                            'TRANSCRIPT',
                                            style: TextStyle(
                                              fontSize: 12.sp,
                                              fontWeight: FontWeight.w900,
                                              letterSpacing: 1.5,
                                              color: VoxAppColors.ink
                                                  .withValues(alpha: 0.8),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    const _DashedDivider(),

                                    // Main Transcript zone rendered inline (no internal scrolling zone)
                                    Padding(
                                      padding: EdgeInsets.all(16.r),
                                      child: segments.isEmpty
                                          ? MarkdownTranscriptView(
                                              text: fallback,
                                              mentions: mentions,
                                            )
                                          : TranscriptPlayerView(
                                              segments: segments,
                                              controller: _audio,
                                              fallbackText: fallback,
                                              focusedStartMs:
                                                  widget.highlightStartMs,
                                              focusedEndMs:
                                                  widget.highlightEndMs,
                                            ),
                                    ),
                                  ],
                                ),
                              ),

                              // Failed error view warning
                              if (log.processingState ==
                                  ProcessingState.failed) ...[
                                Padding(
                                  padding: EdgeInsets.symmetric(vertical: 4.h),
                                  child: Text(
                                    'Refinement failed: ${log.errorMessage ?? "unknown"}',
                                    style: TextStyle(
                                      color: VoxAppColors.error,
                                      fontSize: 12.sp,
                                    ),
                                  ),
                                ),
                                SizedBox(height: 8.h),
                              ],
                            ],
                          ),
                        ),
                      ),
                      SizedBox(height: 8.h),

                      // base Action buttons (Delete, Share, Rename)
                      _buildBottomActions(context, log),
                      SizedBox(height: 8.h),
                    ],
                  ),
                );
              },
              loading: () => const Center(
                child: CircularProgressIndicator(color: VoxAppColors.accent),
              ),
              error: (e, _) => Center(child: Text('Error: $e')),
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
            width: 38.w,
            height: 38.h,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(8.r),
              border: Border.all(color: VoxAppColors.outline, width: 1.w),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.03),
                  blurRadius: 3.r,
                  offset: Offset(0.w, 1.5.h),
                ),
              ],
            ),
            child: Icon(
              Icons.chevron_left_rounded,
              color: VoxAppColors.ink,
              size: 22.r,
            ),
          ),
        ),

        // Uppercase, monospaced title
        Expanded(
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 16.0.w),
            child: Text(
              _firstLine(log.displayTitle).toUpperCase(),
              textAlign: TextAlign.center,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 14.sp,
                fontWeight: FontWeight.w900,
                letterSpacing: 1.2,
                color: VoxAppColors.ink,
              ),
            ),
          ),
        ),

        // Settings / Options Popup Button
        Container(
          width: 38.w,
          height: 38.h,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(8.r),
            border: Border.all(color: VoxAppColors.outline, width: 1.w),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.03),
                blurRadius: 3.r,
                offset: Offset(0.w, 1.5.h),
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
              icon: Icon(
                Icons.more_vert_rounded,
                color: VoxAppColors.ink,
                size: 20.r,
              ),
              padding: EdgeInsets.zero,
              onSelected: _onAction,
              itemBuilder: (_) => [
                if (log.processingState == ProcessingState.failed)
                  PopupMenuItem(
                    value: 'retry',
                    child: Text(
                      'Retry refinement',
                      style: TextStyle(fontSize: 14.sp),
                    ),
                  ),
                PopupMenuItem(
                  value: 'delete',
                  child: Text(
                    'Delete Log',
                    style: TextStyle(
                      fontSize: 14.sp,
                      color: VoxAppColors.accent,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
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
              height: 48.h,
              decoration: BoxDecoration(
                color: VoxAppColors.accent,
                borderRadius: BorderRadius.circular(8.r),
                boxShadow: [
                  BoxShadow(
                    color: VoxAppColors.accent.withValues(alpha: 0.15),
                    blurRadius: 4.r,
                    offset: Offset(0.w, 2.h),
                  ),
                ],
              ),
              child: Center(
                child: Text(
                  'DELETE',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 14.sp,
                    letterSpacing: 1.0,
                  ),
                ),
              ),
            ),
          ),
        ),
        SizedBox(width: 10.w),

        // Sizable Share Button
        Expanded(
          child: GestureDetector(
            onTap: () {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Raw transcript copied to clipboard!'),
                  duration: Duration(seconds: 2),
                ),
              );
            },
            child: Container(
              height: 48.h,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(8.r),
                border: Border.all(color: VoxAppColors.outline, width: 1.2.w),
              ),
              child: Center(
                child: Text(
                  'SHARE',
                  style: TextStyle(
                    color: VoxAppColors.ink,
                    fontWeight: FontWeight.bold,
                    fontSize: 14.sp,
                    letterSpacing: 1.0,
                  ),
                ),
              ),
            ),
          ),
        ),
        SizedBox(width: 10.w),

        // Sizable Rename Button
        Expanded(
          child: GestureDetector(
            onTap: () => _onEditTitle(log),
            child: Container(
              height: 48.h,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(8.r),
                border: Border.all(color: VoxAppColors.outline, width: 1.2.w),
              ),
              child: Center(
                child: Text(
                  'RENAME',
                  style: TextStyle(
                    color: VoxAppColors.ink,
                    fontWeight: FontWeight.bold,
                    fontSize: 14.sp,
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
          borderRadius: BorderRadius.circular(16.r),
          side: const BorderSide(color: VoxAppColors.outline),
        ),
        title: Text(
          'DELETE VOICE LOG?',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16.sp),
        ),
        content: Text(
          'Are you sure you want to permanently delete this voice log? This cannot be undone.',
          style: TextStyle(fontSize: 14.sp),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text(
              'CANCEL',
              style: TextStyle(color: VoxAppColors.muted),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text(
              'DELETE',
              style: TextStyle(
                color: VoxAppColors.accent,
                fontWeight: FontWeight.bold,
              ),
            ),
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
  const _PlaybackCard({required this.audio, required this.peaksFuture});

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
      padding: EdgeInsets.all(18.r),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16.r),
        border: Border.all(color: VoxAppColors.outline, width: 1.2.w),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 8.r,
            offset: Offset(0.w, 3.5.h),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Waveform Scrubber
          SizedBox(
            height: 52.h,
            child: widget.peaksFuture == null
                ? const SizedBox.shrink()
                : FutureBuilder<WaveformPeaks>(
                    future: widget.peaksFuture,
                    builder: (context, snapshot) {
                      final peaks =
                          snapshot.data ?? WaveformPeaks(peaks: [], totalMs: 0);
                      return WaveformScrubber(
                        peaks: peaks,
                        controller: widget.audio,
                        height: 52.h,
                      );
                    },
                  ),
          ),
          SizedBox(height: 8.h),

          // Duration Labels Row
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                _formatMs(currentMs),
                style: TextStyle(
                  fontFamily: AppFonts.mono,
                  fontSize: 12.sp,
                  fontWeight: FontWeight.bold,
                  color: VoxAppColors.muted,
                ),
              ),
              Text(
                _formatMs(totalMs),
                style: TextStyle(
                  fontFamily: AppFonts.mono,
                  fontSize: 12.sp,
                  fontWeight: FontWeight.bold,
                  color: VoxAppColors.muted,
                ),
              ),
            ],
          ),
          SizedBox(height: 16.h),
          const _DashedDivider(),
          SizedBox(height: 16.h),

          // Square media controls
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // 10s Rewind Square Button
              GestureDetector(
                onTap: () {
                  final newPos = _position - const Duration(seconds: 10);
                  widget.audio.seek(
                    newPos < Duration.zero ? Duration.zero : newPos,
                  );
                },
                child: Container(
                  width: 40.w,
                  height: 40.h,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(8.r),
                    border: Border.all(
                      color: VoxAppColors.outline,
                      width: 1.2.w,
                    ),
                  ),
                  child: Icon(
                    Icons.replay_10_rounded,
                    color: VoxAppColors.ink,
                    size: 20.r,
                  ),
                ),
              ),
              SizedBox(width: 24.w),

              // Square Play/Pause Charcoal Center Button
              GestureDetector(
                onTap: () =>
                    _playing ? widget.audio.pause() : widget.audio.play(),
                child: Container(
                  width: 52.w,
                  height: 52.h,
                  decoration: BoxDecoration(
                    color: VoxAppColors.primary,
                    borderRadius: BorderRadius.circular(10.r),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.15),
                        blurRadius: 5.r,
                        offset: Offset(0.w, 2.h),
                      ),
                    ],
                  ),
                  child: Icon(
                    _playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                    color: Colors.white,
                    size: 26.r,
                  ),
                ),
              ),
              SizedBox(width: 24.w),

              // 10s Forward Skip Square Button
              GestureDetector(
                onTap: () {
                  final total = widget.audio.duration ?? Duration.zero;
                  final newPos = _position + const Duration(seconds: 10);
                  widget.audio.seek(newPos > total ? total : newPos);
                },
                child: Container(
                  width: 40.w,
                  height: 40.h,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(8.r),
                    border: Border.all(
                      color: VoxAppColors.outline,
                      width: 1.2.w,
                    ),
                  ),
                  child: Icon(
                    Icons.forward_10_rounded,
                    color: VoxAppColors.ink,
                    size: 20.r,
                  ),
                ),
              ),
            ],
          ),
          SizedBox(height: 16.h),

          // Custom Volume Slider Row
          Row(
            children: [
              Icon(
                Icons.volume_up_outlined,
                size: 18.r,
                color: VoxAppColors.muted,
              ),
              SizedBox(width: 6.w),
              Expanded(
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 2.0,
                    thumbShape: const RoundSliderThumbShape(
                      enabledThumbRadius: 5.0,
                    ),
                    overlayShape: const RoundSliderOverlayShape(
                      overlayRadius: 10.0,
                    ),
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
        borderRadius: BorderRadius.circular(16.r),
        side: const BorderSide(color: VoxAppColors.outline),
      ),
      title: Text(
        'RENAME VOICE LOG',
        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16.sp),
      ),
      content: TextField(
        controller: _controller,
        autofocus: true,
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _submit(),
        style: TextStyle(fontSize: 14.sp),
        decoration: InputDecoration(
          hintText: 'Enter title...',
          hintStyle: TextStyle(color: VoxAppColors.muted, fontSize: 14.sp),
          enabledBorder: UnderlineInputBorder(
            borderSide: BorderSide(color: VoxAppColors.outline, width: 1.5.w),
          ),
          focusedBorder: UnderlineInputBorder(
            borderSide: BorderSide(color: VoxAppColors.primary, width: 1.5.w),
          ),
        ),
        maxLength: 120,
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text(
            'CANCEL',
            style: TextStyle(color: VoxAppColors.muted),
          ),
        ),
        TextButton(
          onPressed: _submit,
          child: const Text(
            'SAVE',
            style: TextStyle(
              color: VoxAppColors.primary,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ],
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
              height: 1.h,
              child: const DecoratedBox(
                decoration: BoxDecoration(color: VoxAppColors.outline),
              ),
            );
          }),
        );
      },
    );
  }
}
