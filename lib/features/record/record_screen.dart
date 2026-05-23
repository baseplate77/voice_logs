import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../app_theme.dart';
import 'recording_providers.dart';
import 'transcribing_indicator.dart';

/// Fullscreen active recording page matching the retro-minimalist premium light-theme design.
///
/// Features hardware-like corner studs, a digital LCD LED running timer readout, a symmetrical
/// vertical bar dancing visualizer, and custom control buttons.
class RecordScreen extends ConsumerStatefulWidget {
  const RecordScreen({super.key});

  @override
  ConsumerState<RecordScreen> createState() => _RecordScreenState();
}

class _RecordScreenState extends ConsumerState<RecordScreen> {
  bool _isPaused = false;
  int? _pausedElapsedMs;

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(recordingControllerProvider);
    final controller = ref.read(recordingControllerProvider.notifier);

    // Auto-pop logic when returning to idle (cancel or save complete)
    ref.listen<RecordingState>(recordingControllerProvider, (previous, next) {
      if (next is RecordingIdle && previous is! RecordingIdle) {
        Navigator.of(context).pop();
      }
    });

    return Scaffold(
      backgroundColor: VoxAppColors.canvas,
      body: SafeArea(
        child: Stack(
          children: [
            // Main UI Layout
            Padding(
              padding: EdgeInsets.symmetric(
                horizontal: 24.0.w,
                vertical: 16.0.h,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Top Custom Header (Back button + Title + Decorative line)
                  SizedBox(height: 12.h),
                  _buildHeader(context),
                  SizedBox(height: 8.h),
                  const _DashedDivider(),

                  // Body Switch
                  Expanded(
                    child: switch (state) {
                      RecordingIdle() => _IdleStandbyView(
                        onStart: controller.start,
                      ),
                      RecordingActive(:final elapsedMs) => _ActiveRecordingView(
                        elapsedMs: elapsedMs,
                        isPaused: _isPaused,
                        pausedElapsedMs: _pausedElapsedMs,
                        waveformLevels: controller.waveformLevels,
                        onTogglePause: (paused) {
                          setState(() {
                            _isPaused = paused;
                            if (paused) {
                              _pausedElapsedMs = elapsedMs;
                            } else {
                              _pausedElapsedMs = null;
                            }
                          });
                        },
                        onCancel: () async {
                          final confirm = await _showCancelDialog(context);
                          if (confirm == true) {
                            await controller.cancel();
                          }
                        },
                        onDone: controller.stop,
                      ),
                      RecordingTranscribing() => const _RetroTranscribingView(),
                      RecordingFailed(:final message) => _FailedRetryView(
                        message: message,
                        onRetry: controller.start,
                      ),
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        // Retro White Square Back Button
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

        Text(
          'VOICE RECORDING',
          style: TextStyle(
            fontSize: 14.sp,
            fontWeight: FontWeight.w900,
            letterSpacing: 1.8,
            color: VoxAppColors.ink.withValues(alpha: 0.8),
          ),
        ),

        // Symmetrical empty block to center the title
        SizedBox(width: 38.w),
      ],
    );
  }

  Future<bool?> _showCancelDialog(BuildContext context) {
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
          'DISCARD RECORDING?',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16.sp),
        ),
        content: Text(
          'This will permanently delete the current voice recording. Are you sure?',
          style: TextStyle(fontSize: 14.sp),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text(
              'KEEP',
              style: TextStyle(color: VoxAppColors.muted),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text(
              'DISCARD',
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
}

class _IdleStandbyView extends StatelessWidget {
  const _IdleStandbyView({required this.onStart});
  final Future<void> Function() onStart;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        // Standby LED display panel
        Container(
          padding: EdgeInsets.symmetric(horizontal: 24.w, vertical: 16.h),
          decoration: BoxDecoration(
            color: VoxAppColors.primary,
            borderRadius: BorderRadius.circular(12.r),
            border: Border.all(color: const Color(0xFF333333), width: 1.5.w),
          ),
          child: Stack(
            alignment: Alignment.center,
            children: [
              Opacity(
                opacity: 0.08,
                child: Text(
                  '88:88:88',
                  style: TextStyle(
                    fontSize: 44.sp,
                    fontFamily: 'IBMPlexMono',
                    fontWeight: FontWeight.w900,
                    color: VoxAppColors.accent,
                    letterSpacing: 2,
                  ),
                ),
              ),
              Text(
                '00:00:00',
                style: TextStyle(
                  fontSize: 44.sp,
                  fontFamily: 'IBMPlexMono',
                  fontWeight: FontWeight.w900,
                  color: Colors.white24,
                  letterSpacing: 2,
                ),
              ),
            ],
          ),
        ),
        SizedBox(height: 24.h),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 8.w,
              height: 8.h,
              decoration: const BoxDecoration(
                color: VoxAppColors.muted,
                shape: BoxShape.circle,
              ),
            ),
            SizedBox(width: 8.w),
            Text(
              'STANDBY',
              style: TextStyle(
                fontFamily: 'IBMPlexMono',
                fontSize: 12.sp,
                fontWeight: FontWeight.bold,
                color: VoxAppColors.muted,
                letterSpacing: 1.2,
              ),
            ),
          ],
        ),
        SizedBox(height: 64.h),

        // Large retro Record button
        GestureDetector(
          onTap: () async => onStart(),
          child: Container(
            width: 100.w,
            height: 100.h,
            decoration: BoxDecoration(
              color: Colors.white,
              shape: BoxShape.circle,
              border: Border.all(color: VoxAppColors.outline, width: 2.w),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.06),
                  blurRadius: 8.r,
                  offset: Offset(0.w, 4.h),
                ),
              ],
            ),
            child: Center(
              child: Container(
                width: 76.w,
                height: 76.h,
                decoration: BoxDecoration(
                  color: VoxAppColors.accent,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 3.w),
                  boxShadow: [
                    BoxShadow(
                      color: VoxAppColors.accent.withValues(alpha: 0.3),
                      blurRadius: 8.r,
                      offset: Offset(0.w, 3.h),
                    ),
                  ],
                ),
                child: Icon(Icons.mic_rounded, color: Colors.white, size: 32.r),
              ),
            ),
          ),
        ),
        SizedBox(height: 16.h),
        Text(
          'Tap to start recording',
          style: TextStyle(
            fontSize: 13.sp,
            fontWeight: FontWeight.w500,
            color: VoxAppColors.muted,
            letterSpacing: 0.2,
          ),
        ),
      ],
    );
  }
}

class _ActiveRecordingView extends StatelessWidget {
  const _ActiveRecordingView({
    required this.elapsedMs,
    required this.isPaused,
    required this.pausedElapsedMs,
    required this.waveformLevels,
    required this.onTogglePause,
    required this.onCancel,
    required this.onDone,
  });

  final int elapsedMs;
  final bool isPaused;
  final int? pausedElapsedMs;
  final List<double> waveformLevels;
  final ValueChanged<bool> onTogglePause;
  final VoidCallback onCancel;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    final activeMs = isPaused ? (pausedElapsedMs ?? elapsedMs) : elapsedMs;
    final timeStr = _formatDuration(activeMs);

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Spacer(),

        // LED Display Box
        Container(
          padding: EdgeInsets.symmetric(horizontal: 28.w, vertical: 18.h),
          decoration: BoxDecoration(
            color: VoxAppColors.primary,
            borderRadius: BorderRadius.circular(12.r),
            border: Border.all(color: const Color(0xFF2E2E30), width: 2.w),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.15),
                blurRadius: 10.r,
                offset: Offset(0.w, 5.h),
              ),
            ],
          ),
          child: Stack(
            alignment: Alignment.center,
            children: [
              Opacity(
                opacity: 0.06,
                child: Text(
                  '88:88:88',
                  style: TextStyle(
                    fontSize: 46.sp,
                    fontFamily: 'IBMPlexMono',
                    fontWeight: FontWeight.w900,
                    color: VoxAppColors.accent,
                    letterSpacing: 2.2,
                  ),
                ),
              ),
              Text(
                timeStr,
                style: TextStyle(
                  fontSize: 46.sp,
                  fontFamily: 'IBMPlexMono',
                  fontWeight: FontWeight.w900,
                  color: isPaused ? VoxAppColors.muted : VoxAppColors.accent,
                  letterSpacing: 2.2,
                  shadows: isPaused
                      ? []
                      : [
                          Shadow(
                            color: VoxAppColors.accent.withValues(alpha: 0.5),
                            blurRadius: 12.r,
                          ),
                        ],
                ),
              ),
            ],
          ),
        ),

        SizedBox(height: 18.h),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _BlinkingDot(isPaused: isPaused),
            SizedBox(width: 8.w),
            Text(
              isPaused ? 'PAUSED' : 'RECORDING',
              style: TextStyle(
                fontFamily: 'IBMPlexMono',
                fontSize: 12.sp,
                fontWeight: FontWeight.bold,
                color: isPaused ? VoxAppColors.muted : VoxAppColors.accent,
                letterSpacing: 1.2,
              ),
            ),
          ],
        ),

        const Spacer(),

        // Symmetrical Symmetrical dancing visualizer
        SizedBox(
          height: 120.h,
          child: Center(
            child: _DancingVisualizer(
              levels: waveformLevels,
              isPaused: isPaused,
            ),
          ),
        ),

        const Spacer(),

        // Symmetrical Controls (Cancel - Pause - Done)
        Padding(
          padding: EdgeInsets.symmetric(horizontal: 16.0.w),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              // Cancel Circle Button
              GestureDetector(
                onTap: onCancel,
                child: Container(
                  width: 52.w,
                  height: 52.h,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: VoxAppColors.outline,
                      width: 1.2.w,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.04),
                        blurRadius: 4.r,
                        offset: Offset(0.w, 2.h),
                      ),
                    ],
                  ),
                  child: Icon(
                    Icons.close_rounded,
                    color: VoxAppColors.ink,
                    size: 22.r,
                  ),
                ),
              ),

              // Wide Stadium Pause Button
              GestureDetector(
                onTap: () => onTogglePause(!isPaused),
                child: Container(
                  width: 140.w,
                  height: 52.h,
                  decoration: BoxDecoration(
                    color: VoxAppColors.primary,
                    borderRadius: BorderRadius.circular(26.r),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.12),
                        blurRadius: 5.r,
                        offset: Offset(0.w, 2.5.h),
                      ),
                    ],
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        isPaused
                            ? Icons.play_arrow_rounded
                            : Icons.pause_rounded,
                        color: Colors.white,
                        size: 20.r,
                      ),
                      SizedBox(width: 8.w),
                      Text(
                        isPaused ? 'RESUME' : 'PAUSE',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1.2,
                          fontSize: 14.sp,
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              // Done Checkmark Circle Button
              GestureDetector(
                onTap: onDone,
                child: Container(
                  width: 52.w,
                  height: 52.h,
                  decoration: BoxDecoration(
                    color: VoxAppColors.accent,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: VoxAppColors.accent,
                      width: 1.2.w,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: VoxAppColors.accent.withValues(alpha: 0.2),
                        blurRadius: 5.r,
                        offset: Offset(0.w, 2.5.h),
                      ),
                    ],
                  ),
                  child: Icon(
                    Icons.check_rounded,
                    color: Colors.white,
                    size: 22.r,
                  ),
                ),
              ),
            ],
          ),
        ),
        SizedBox(height: 24.h),
      ],
    );
  }

  String _formatDuration(int ms) {
    final totalSec = ms ~/ 1000;
    final hr = totalSec ~/ 3600;
    final min = (totalSec % 3600) ~/ 60;
    final sec = totalSec % 60;
    final hs = hr.toString().padLeft(2, '0');
    final msStr = min.toString().padLeft(2, '0');
    final ss = sec.toString().padLeft(2, '0');
    return '$hs:$msStr:$ss';
  }
}

class _BlinkingDot extends StatefulWidget {
  const _BlinkingDot({required this.isPaused});
  final bool isPaused;

  @override
  State<_BlinkingDot> createState() => _BlinkingDotState();
}

class _BlinkingDotState extends State<_BlinkingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    if (!widget.isPaused) {
      _controller.repeat(reverse: true);
    }
  }

  @override
  void didUpdateWidget(covariant _BlinkingDot oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isPaused) {
      _controller.stop();
      _controller.value = 1.0;
    } else {
      _controller.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) => Opacity(
        opacity: _controller.value,
        child: Container(
          width: 8.w,
          height: 8.h,
          decoration: BoxDecoration(
            color: widget.isPaused ? VoxAppColors.muted : VoxAppColors.accent,
            shape: BoxShape.circle,
          ),
        ),
      ),
    );
  }
}

class _DancingVisualizer extends StatelessWidget {
  const _DancingVisualizer({required this.levels, required this.isPaused});
  final List<double> levels;
  final bool isPaused;

  /// Linearly interpolates [src] to twice its length by inserting a
  /// midpoint sample between each adjacent pair. The last output element
  /// repeats the source's tail so the result has exactly `2 * src.length`
  /// values — keeping the symmetrical mirroring math below clean.
  List<double> _upsample(List<double> src) {
    if (src.isEmpty) return const [];
    final out = <double>[];
    for (var i = 0; i < src.length; i++) {
      out.add(src[i]);
      final next = i + 1 < src.length ? src[i + 1] : src[i];
      out.add((src[i] + next) / 2);
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    // Source levels are N samples; upsample 2× then mirror to get a
    // symmetrical 4N-column visualizer. With the default 12-level source
    // this produces 48 columns (was 24) for a denser dot pattern.
    final dense = _upsample(levels);
    final mirroredLevels = [...dense.reversed, ...dense];

    return RepaintBoundary(
      child: SizedBox.expand(
        child: CustomPaint(
          painter: _DancingVisualizerPainter(
            levels: mirroredLevels,
            isPaused: isPaused,
          ),
        ),
      ),
    );
  }
}

class _DancingVisualizerPainter extends CustomPainter {
  _DancingVisualizerPainter({required this.levels, required this.isPaused});

  final List<double> levels;
  final bool isPaused;

  @override
  void paint(Canvas canvas, Size size) {
    final barCount = levels.length;
    if (barCount == 0) return;

    final spacing = size.width / barCount;
    // Tighter clamp than before (was 4.5–12) so the grid stays dense even
    // on wider phones where horizontal spacing would otherwise grow.
    final vSpacing = spacing.clamp(3.0, 6.0);
    // Smaller dots to suit the denser packing.
    final dotRadius = (spacing * 0.30).clamp(1.0, 2.8);
    final mid = size.height / 2;
    final maxDotsPerSide = (size.height / 2) ~/ vSpacing;

    // 1. Draw a uniform background grid of faint dots
    final gridPaint = Paint()..color = const Color(0xFFEAEAEA);
    for (var i = 0; i < barCount; i++) {
      final x = spacing * i + spacing / 2;
      for (var j = 1; j <= maxDotsPerSide; j++) {
        canvas.drawCircle(Offset(x, mid - j * vSpacing), dotRadius, gridPaint);
        canvas.drawCircle(Offset(x, mid + j * vSpacing), dotRadius, gridPaint);
      }
    }

    // Central accent emphasises the middle third of the symmetric grid;
    // computed proportionally so it scales with [barCount].
    final centralStart = barCount ~/ 3;
    final centralEnd = (barCount * 2) ~/ 3;

    // 2. Draw centerline and active amplitude dots
    for (var i = 0; i < barCount; i++) {
      final x = spacing * i + spacing / 2;
      final isCentral = i >= centralStart && i < centralEnd;
      final baseColor = isCentral ? VoxAppColors.accent : VoxAppColors.primary;

      // Centerline dot is always retro red (VoxAppColors.accent)
      final centerlinePaint = Paint()..color = VoxAppColors.accent;
      canvas.drawCircle(Offset(x, mid), dotRadius * 1.1, centerlinePaint);

      // Active amplitude dots
      final level = levels[i];
      final rawActiveDots = isPaused ? 0 : (level * maxDotsPerSide).round();
      final activeDots = rawActiveDots.clamp(0, maxDotsPerSide);

      for (var j = 1; j <= activeDots; j++) {
        double opacity = 1.0 - (j / (maxDotsPerSide + 1)) * 0.7;
        if (isPaused) {
          opacity *= 0.3;
        }
        final activePaint = Paint()
          ..color = baseColor.withValues(alpha: opacity.clamp(0.0, 1.0));

        canvas.drawCircle(
          Offset(x, mid - j * vSpacing),
          dotRadius,
          activePaint,
        );
        canvas.drawCircle(
          Offset(x, mid + j * vSpacing),
          dotRadius,
          activePaint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_DancingVisualizerPainter old) {
    if (old.isPaused != isPaused || old.levels.length != levels.length) {
      return true;
    }
    for (var i = 0; i < levels.length; i++) {
      if (old.levels[i] != levels[i]) return true;
    }
    return false;
  }
}

class _RetroTranscribingView extends StatelessWidget {
  const _RetroTranscribingView();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        margin: EdgeInsets.symmetric(horizontal: 16.w),
        padding: EdgeInsets.all(28.r),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16.r),
          border: Border.all(color: VoxAppColors.outline, width: 1.w),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.05),
              blurRadius: 10.r,
              offset: Offset(0.w, 4.h),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TranscribingIndicator(size: 48.r),
            SizedBox(height: 24.h),
            Text(
              'PROCESSING AUDIO',
              style: TextStyle(
                fontFamily: 'IBMPlexMono',
                fontSize: 14.sp,
                fontWeight: FontWeight.w900,
                letterSpacing: 1.5,
                color: VoxAppColors.ink,
              ),
            ),
            SizedBox(height: 12.h),
            const _DashedDivider(),
            SizedBox(height: 12.h),
            _consoleLine('DECODING 16KHZ MONO PCM ISOLATE...'),
            SizedBox(height: 6.h),
            _consoleLine('RUNNING PARAKEET ASR ENGINE...'),
            SizedBox(height: 6.h),
            _consoleLine('PRESERVING ENCRYPTED JOURNAL LOG...'),
          ],
        ),
      ),
    );
  }

  Widget _consoleLine(String text) {
    return Row(
      children: [
        Text(
          '> ',
          style: TextStyle(
            color: VoxAppColors.accent,
            fontSize: 12.sp,
            fontFamily: 'IBMPlexMono',
            fontWeight: FontWeight.bold,
          ),
        ),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              color: VoxAppColors.muted,
              fontSize: 12.sp,
              fontFamily: 'IBMPlexMono',
            ),
          ),
        ),
      ],
    );
  }
}

class _FailedRetryView extends StatelessWidget {
  const _FailedRetryView({required this.message, required this.onRetry});
  final String message;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 24.w),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.error_outline_rounded,
            size: 52.r,
            color: VoxAppColors.accent,
          ),
          SizedBox(height: 16.h),
          Text(
            'Capture error',
            style: TextStyle(
              fontSize: 17.sp,
              fontWeight: FontWeight.w700,
              color: VoxAppColors.ink,
            ),
          ),
          SizedBox(height: 8.h),
          Text(
            message,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 14.sp, color: VoxAppColors.muted),
          ),
          SizedBox(height: 32.h),
          GestureDetector(
            onTap: () async => onRetry(),
            child: Container(
              padding: EdgeInsets.symmetric(horizontal: 32.w, vertical: 14.h),
              decoration: BoxDecoration(
                color: VoxAppColors.primary,
                borderRadius: BorderRadius.circular(8.r),
              ),
              child: Text(
                'Try again',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                  fontSize: 14.sp,
                ),
              ),
            ),
          ),
        ],
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
