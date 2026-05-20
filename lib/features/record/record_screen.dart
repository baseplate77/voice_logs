import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
            // Four Corner Screws/Studs for hardware look
            const Positioned(left: 10, top: 10, child: _SilverStud()),
            const Positioned(right: 10, top: 10, child: _SilverStud()),
            const Positioned(left: 10, bottom: 10, child: _SilverStud()),
            const Positioned(right: 10, bottom: 10, child: _SilverStud()),

            // Main UI Layout
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Top Custom Header (Back button + Title + Decorative line)
                  const SizedBox(height: 12),
                  _buildHeader(context),
                  const SizedBox(height: 8),
                  const _DashedDivider(),
                  
                  // Body Switch
                  Expanded(
                    child: switch (state) {
                      RecordingIdle() => _IdleStandbyView(onStart: controller.start),
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
        
        // Monospaced Title
        Text(
          'VOICE RECORDING',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w900,
            fontFamily: 'monospace',
            letterSpacing: 1.8,
            color: VoxAppColors.ink.withValues(alpha: 0.8),
          ),
        ),
        
        // Symmetrical empty block to center the title
        const SizedBox(width: 38),
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
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: VoxAppColors.outline),
        ),
        title: const Text(
          'DISCARD RECORDING?',
          style: TextStyle(fontFamily: 'monospace', fontWeight: FontWeight.bold, fontSize: 16),
        ),
        content: const Text(
          'This will permanently delete the current voice recording. Are you sure?',
          style: TextStyle(fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('KEEP', style: TextStyle(color: VoxAppColors.muted, fontFamily: 'monospace')),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('DISCARD', style: TextStyle(color: VoxAppColors.accent, fontWeight: FontWeight.bold, fontFamily: 'monospace')),
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
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          decoration: BoxDecoration(
            color: VoxAppColors.primary,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFF333333), width: 1.5),
          ),
          child: Stack(
            alignment: Alignment.center,
            children: [
              Opacity(
                opacity: 0.08,
                child: Text(
                  '88:88:88',
                  style: TextStyle(
                    fontSize: 44,
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.w900,
                    color: VoxAppColors.accent,
                    letterSpacing: 2,
                  ),
                ),
              ),
              const Text(
                '00:00:00',
                style: TextStyle(
                  fontSize: 44,
                  fontFamily: 'monospace',
                  fontWeight: FontWeight.w900,
                  color: Colors.white24,
                  letterSpacing: 2,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: const BoxDecoration(
                color: VoxAppColors.muted,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 8),
            const Text(
              'STANDBY',
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: VoxAppColors.muted,
                letterSpacing: 1.2,
              ),
            ),
          ],
        ),
        const SizedBox(height: 64),
        
        // Large retro Record button
        GestureDetector(
          onTap: () async => onStart(),
          child: Container(
            width: 100,
            height: 100,
            decoration: BoxDecoration(
              color: Colors.white,
              shape: BoxShape.circle,
              border: Border.all(color: VoxAppColors.outline, width: 2),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.06),
                  blurRadius: 8,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Center(
              child: Container(
                width: 76,
                height: 76,
                decoration: BoxDecoration(
                  color: VoxAppColors.accent,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 3),
                  boxShadow: [
                    BoxShadow(
                      color: VoxAppColors.accent.withValues(alpha: 0.3),
                      blurRadius: 8,
                      offset: const Offset(0, 3),
                    ),
                  ],
                ),
                child: const Icon(
                  Icons.mic_rounded,
                  color: Colors.white,
                  size: 32,
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 16),
        const Text(
          'TAP TO START RECORDING',
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.bold,
            color: VoxAppColors.muted,
            letterSpacing: 1.0,
            fontFamily: 'monospace',
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
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 18),
          decoration: BoxDecoration(
            color: VoxAppColors.primary,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFF2E2E30), width: 2),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.15),
                blurRadius: 10,
                offset: const Offset(0, 5),
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
                    fontSize: 46,
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.w900,
                    color: VoxAppColors.accent,
                    letterSpacing: 2.2,
                  ),
                ),
              ),
              Text(
                timeStr,
                style: TextStyle(
                  fontSize: 46,
                  fontFamily: 'monospace',
                  fontWeight: FontWeight.w900,
                  color: isPaused ? VoxAppColors.muted : VoxAppColors.accent,
                  letterSpacing: 2.2,
                  shadows: isPaused ? [] : [
                    Shadow(
                      color: VoxAppColors.accent.withValues(alpha: 0.5),
                      blurRadius: 12,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        
        const SizedBox(height: 18),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _BlinkingDot(isPaused: isPaused),
            const SizedBox(width: 8),
            Text(
              isPaused ? 'PAUSED' : 'RECORDING',
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
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
          height: 120,
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
          padding: const EdgeInsets.symmetric(horizontal: 16.0),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              // Cancel Circle Button
              GestureDetector(
                onTap: onCancel,
                child: Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    shape: BoxShape.circle,
                    border: Border.all(color: VoxAppColors.outline, width: 1.2),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.04),
                        blurRadius: 4,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: const Icon(
                    Icons.close_rounded,
                    color: VoxAppColors.ink,
                    size: 22,
                  ),
                ),
              ),
              
              // Wide Stadium Pause Button
              GestureDetector(
                onTap: () => onTogglePause(!isPaused),
                child: Container(
                  width: 140,
                  height: 52,
                  decoration: BoxDecoration(
                    color: VoxAppColors.primary,
                    borderRadius: BorderRadius.circular(26),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.12),
                        blurRadius: 5,
                        offset: const Offset(0, 2.5),
                      ),
                    ],
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        isPaused ? Icons.play_arrow_rounded : Icons.pause_rounded,
                        color: Colors.white,
                        size: 20,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        isPaused ? 'RESUME' : 'PAUSE',
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontFamily: 'monospace',
                          letterSpacing: 1.2,
                          fontSize: 13,
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
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(
                    color: VoxAppColors.accent,
                    shape: BoxShape.circle,
                    border: Border.all(color: VoxAppColors.accent, width: 1.2),
                    boxShadow: [
                      BoxShadow(
                        color: VoxAppColors.accent.withValues(alpha: 0.2),
                        blurRadius: 5,
                        offset: const Offset(0, 2.5),
                      ),
                    ],
                  ),
                  child: const Icon(
                    Icons.check_rounded,
                    color: Colors.white,
                    size: 22,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
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

class _BlinkingDotState extends State<_BlinkingDot> with SingleTickerProviderStateMixin {
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
          width: 8,
          height: 8,
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

  @override
  Widget build(BuildContext context) {
    // We construct a symmetrical layout of 24 bars from the 12 input levels
    final mirroredLevels = [...levels.reversed, ...levels];
    final barCount = mirroredLevels.length;

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: List.generate(barCount, (index) {
        final level = mirroredLevels[index];
        final rawHeight = isPaused ? 6.0 : (level * 105.0);
        final height = rawHeight.clamp(6.0, 110.0);

        // Highlight central bars in retro red
        final isCentral = index >= 8 && index < 16;
        final color = isCentral
            ? VoxAppColors.accent.withValues(alpha: isPaused ? 0.35 : 0.95)
            : VoxAppColors.primary.withValues(alpha: isPaused ? 0.2 : 0.7);

        return AnimatedContainer(
          duration: const Duration(milliseconds: 100),
          width: 4.5,
          height: height,
          margin: const EdgeInsets.symmetric(horizontal: 2.0),
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(2.2),
          ),
        );
      }),
    );
  }
}

class _RetroTranscribingView extends StatelessWidget {
  const _RetroTranscribingView();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 16),
        padding: const EdgeInsets.all(28),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: VoxAppColors.outline, width: 1),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.05),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const TranscribingIndicator(size: 48),
            const SizedBox(height: 24),
            const Text(
              'PROCESSING AUDIO',
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 14,
                fontWeight: FontWeight.w900,
                letterSpacing: 1.5,
                color: VoxAppColors.ink,
              ),
            ),
            const SizedBox(height: 12),
            const _DashedDivider(),
            const SizedBox(height: 12),
            _consoleLine('DECODING 16KHZ MONO PCM ISOLATE...'),
            const SizedBox(height: 6),
            _consoleLine('RUNNING PARAKEET ASR ENGINE...'),
            const SizedBox(height: 6),
            _consoleLine('PRESERVING ENCRYPTED JOURNAL LOG...'),
          ],
        ),
      ),
    );
  }

  Widget _consoleLine(String text) {
    return Row(
      children: [
        const Text(
          '> ',
          style: TextStyle(
            color: VoxAppColors.accent,
            fontSize: 10,
            fontFamily: 'monospace',
            fontWeight: FontWeight.bold,
          ),
        ),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(
              color: VoxAppColors.muted,
              fontSize: 10,
              fontFamily: 'monospace',
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
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.error_outline_rounded,
            size: 52,
            color: VoxAppColors.accent,
          ),
          const SizedBox(height: 16),
          const Text(
            'CAPTURE ERROR',
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 16,
              fontWeight: FontWeight.w900,
              letterSpacing: 1.5,
              color: VoxAppColors.ink,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 13, color: VoxAppColors.muted),
          ),
          const SizedBox(height: 32),
          GestureDetector(
            onTap: () async => onRetry(),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 14),
              decoration: BoxDecoration(
                color: VoxAppColors.primary,
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text(
                'TRY AGAIN',
                style: TextStyle(
                  color: Colors.white,
                  fontFamily: 'monospace',
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.0,
                  fontSize: 13,
                ),
              ),
            ),
          ),
        ],
      ),
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
