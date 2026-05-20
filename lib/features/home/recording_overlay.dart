import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app_theme.dart';
import '../../core/logger.dart';
import '../ask/ask_screen.dart';
import '../record/record_screen.dart';
import '../record/recording_providers.dart';
import '../record/transcribing_indicator.dart';
import '../settings/settings_screen.dart';
import 'two_tone_palette.dart';

final _log = Logger('recording_overlay');

/// The bottom navigation deck containing stateful control actions.
/// Designed to sit on top of the black canvas exposed under the lifted home screen panel.
class RecordingOverlay extends ConsumerWidget {
  const RecordingOverlay({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(recordingControllerProvider);
    final controller = ref.read(recordingControllerProvider.notifier);
    _log.d('build state=${state.runtimeType}');

    final double bottomPadding = MediaQuery.paddingOf(context).bottom;
    final double barHeight =
        58.0 + bottomPadding; // Reduced base height to 58.0

    return SizedBox(
      height: barHeight,
      width: double.infinity,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // Content aligned within the 64px zone, leaving safe area spacing below
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            height: 58,
            child: AnimatedSize(
              duration: const Duration(milliseconds: 240),
              curve: Curves.easeOut,
              child: switch (state) {
                RecordingIdle() => _IdleDeck(
                  onStart: () async {
                    await controller.start();
                    if (context.mounted) {
                      await Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const RecordScreen(),
                        ),
                      );
                    }
                  },
                ),
                RecordingActive(:final elapsedMs) => _ActiveDeck(
                  elapsedMs: elapsedMs,
                  onStop: controller.stop,
                ),
                RecordingTranscribing() => const _TranscribingDeck(),
                RecordingFailed(:final message) => _FailedDeck(
                  message: message,
                  onRetry: controller.start,
                ),
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// Symmetrical large tactile circular button frame with outer white ring and black base.
class _LargeRecordButton extends StatelessWidget {
  const _LargeRecordButton({required this.onPressed, required this.child});
  final VoidCallback onPressed;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onPressed,
      customBorder: const CircleBorder(),
      child: Container(
        width: 100,
        height: 100,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors
              .transparent, // transparent inside so the dark background shows through
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.95),
            width: 1.5,
          ),
        ),
        padding: const EdgeInsets.all(
          9,
        ), // creates the perfect 9px gap all around for the dual-ring effect
        child: child,
      ),
    );
  }
}

/// Idle deck: home icon on left, settings icon on right, and massive record button.
class _IdleDeck extends StatelessWidget {
  const _IdleDeck({required this.onStart});
  final VoidCallback onStart;

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        // Sidebar Navigation Actions - lowered using top: 12 padding
        Positioned.fill(
          child: Padding(
            padding: const EdgeInsets.only(left: 48, right: 48, top: 12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                IconButton(
                  icon: const CustomHomeIcon(color: Colors.white, size: 26),
                  tooltip: 'Chat',
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(builder: (_) => const AskScreen()),
                  ),
                ),
                IconButton(
                  icon: const CustomSettingsIcon(color: Colors.white, size: 26),
                  tooltip: 'Settings',
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const SettingsScreen(),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        // Symmetrical large tactile Record Button sitting precisely inside the scoop
        Positioned(
          top: -46, // Adjusted top position for 58px bar height
          left: 0,
          right: 0,
          child: Center(
            child: _LargeRecordButton(
              onPressed: onStart,
              child: Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.5),
                      blurRadius: 4,
                      offset: const Offset(0, 3),
                    ),
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.25),
                      blurRadius: 8,
                      offset: const Offset(0, 1),
                    ),
                  ],
                  gradient: const RadialGradient(
                    center: Alignment(-0.25, -0.25),
                    radius: 0.85,
                    colors: [
                      Color(0xFFFF3B30), // bright retro red
                      Color(0xFFC71C1C), // deep red
                      Color(0xFF800606), // darker red for shadowy median effect
                    ],
                    stops: [0.0, 0.75, 1.0],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Active deck: pulsing dot and status on left, timer on right, and stop button.
class _ActiveDeck extends StatelessWidget {
  const _ActiveDeck({required this.elapsedMs, required this.onStop});
  final int elapsedMs;
  final Future<void> Function() onStop;

  @override
  Widget build(BuildContext context) {
    final minutes = (elapsedMs ~/ 60000).toString().padLeft(2, '0');
    final seconds = ((elapsedMs ~/ 1000) % 60).toString().padLeft(2, '0');

    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned.fill(
          child: Padding(
            padding: const EdgeInsets.only(left: 36, right: 36, top: 12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const _PulsingDot(),
                    const SizedBox(width: 8),
                    Text(
                      'REC',
                      style: labelCaps(VoxAppColors.accent).copyWith(
                        fontSize: 10,
                        letterSpacing: 1.5,
                        color: VoxAppColors.accent,
                      ),
                    ),
                  ],
                ),
                Text(
                  '$minutes:$seconds',
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                    fontFamily: 'monospace',
                  ),
                ),
              ],
            ),
          ),
        ),
        // Stop button nested inside the scoop
        Positioned(
          top: -36,
          left: 0,
          right: 0,
          child: Center(
            child: _LargeRecordButton(
              onPressed: () async => onStop(),
              child: Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.5),
                      blurRadius: 4,
                      offset: const Offset(0, 3),
                    ),
                  ],
                  gradient: const RadialGradient(
                    center: Alignment(-0.25, -0.25),
                    radius: 0.85,
                    colors: [
                      Color(0xFFFF3B30), // bright retro red
                      Color(0xFFC71C1C), // deep red
                      Color(0xFF800606), // darker red for shadowy median effect
                    ],
                    stops: [0.0, 0.75, 1.0],
                  ),
                ),
                child: Center(
                  child: Container(
                    width: 20,
                    height: 20,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(4),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.3),
                          blurRadius: 2,
                          offset: const Offset(0, 1),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Transcribing deck: loading labels flanking a transcribing spinner in the scoop.
class _TranscribingDeck extends StatelessWidget {
  const _TranscribingDeck();

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        const Positioned.fill(
          child: Padding(
            padding: EdgeInsets.only(left: 36, right: 36, top: 12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'VOXSYNTH',
                  style: TextStyle(
                    fontSize: 9,
                    fontWeight: FontWeight.bold,
                    color: Colors.white54,
                    letterSpacing: 2.0,
                    fontFamily: 'monospace',
                  ),
                ),
                Text(
                  'PROCESSING...',
                  style: TextStyle(
                    fontSize: 9,
                    fontWeight: FontWeight.bold,
                    color: Colors.white54,
                    letterSpacing: 1.0,
                    fontFamily: 'monospace',
                  ),
                ),
              ],
            ),
          ),
        ),
        // Transcribing indicator in the scoop
        Positioned(
          top: -36,
          left: 0,
          right: 0,
          child: Center(
            child: _LargeRecordButton(
              onPressed: () {},
              child: Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: const Color(0xFF1E1F22),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.3),
                      blurRadius: 4,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: const Center(child: TranscribingIndicator(size: 24)),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Failed deck: error message on the left, retry button in the scoop.
class _FailedDeck extends StatelessWidget {
  const _FailedDeck({required this.message, required this.onRetry});
  final String message;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned.fill(
          child: Padding(
            padding: const EdgeInsets.only(left: 24, right: 90, top: 12),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                message,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.redAccent,
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  fontFamily: 'monospace',
                ),
              ),
            ),
          ),
        ),
        // Retry circular button inside the scoop
        Positioned(
          top: -36,
          left: 0,
          right: 0,
          child: Center(
            child: _LargeRecordButton(
              onPressed: () async => onRetry(),
              child: Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.5),
                      blurRadius: 4,
                      offset: const Offset(0, 3),
                    ),
                  ],
                  gradient: const RadialGradient(
                    center: Alignment(-0.25, -0.25),
                    radius: 0.85,
                    colors: [
                      Color(0xFFFF3B30),
                      Color(0xFFC71C1C),
                      Color(0xFF800606),
                    ],
                    stops: [0.0, 0.75, 1.0],
                  ),
                ),
                child: const Icon(
                  Icons.refresh_rounded,
                  color: Colors.white,
                  size: 26,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _PulsingDot extends StatefulWidget {
  const _PulsingDot();

  @override
  State<_PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<_PulsingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween<double>(begin: 0.3, end: 1.0).animate(_controller),
      child: Container(
        width: 8,
        height: 8,
        decoration: const BoxDecoration(
          color: VoxAppColors.accent,
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}

/// Custom painted premium outline Home icon (pentagonal shield house).
class CustomHomeIcon extends StatelessWidget {
  final Color color;
  final double size;

  const CustomHomeIcon({super.key, required this.color, this.size = 28});

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size(size, size),
      painter: _HomeIconPainter(color: color),
    );
  }
}

class _HomeIconPainter extends CustomPainter {
  final Color color;
  _HomeIconPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final w = size.width;
    final h = size.height;

    final path = Path();
    path.moveTo(w / 2, 0); // Peak
    path.lineTo(w * 0.1, h * 0.45); // Left roof
    path.quadraticBezierTo(w * 0.1, h * 0.85, w * 0.22, h * 0.9); // Left corner
    path.quadraticBezierTo(w / 2, h * 0.98, w * 0.78, h * 0.9); // Bottom curve
    path.quadraticBezierTo(
      w * 0.9,
      h * 0.85,
      w * 0.9,
      h * 0.45,
    ); // Right corner
    path.close();

    canvas.drawPath(path, paint);

    // Inner door curved line
    final doorPath = Path();
    doorPath.moveTo(w * 0.36, h * 0.65);
    doorPath.quadraticBezierTo(w / 2, h * 0.76, w * 0.64, h * 0.65);
    canvas.drawPath(doorPath, paint);
  }

  @override
  bool shouldRepaint(covariant _HomeIconPainter oldDelegate) => false;
}

/// Custom painted premium outline Settings icon (hexagonal industrial nut).
class CustomSettingsIcon extends StatelessWidget {
  final Color color;
  final double size;

  const CustomSettingsIcon({super.key, required this.color, this.size = 28});

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size(size, size),
      painter: _SettingsIconPainter(color: color),
    );
  }
}

class _SettingsIconPainter extends CustomPainter {
  final Color color;
  _SettingsIconPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final w = size.width;
    final h = size.height;
    final cx = w / 2;
    final cy = h / 2;
    final r = w / 2;

    // Draw Hexagonal outer border
    final path = Path();
    for (int i = 0; i < 6; i++) {
      final double angle = (i * 60 - 30) * math.pi / 180;
      final double x = cx + r * 0.95 * math.cos(angle);
      final double y = cy + r * 0.95 * math.sin(angle);
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    path.close();
    canvas.drawPath(path, paint);

    // Inner core circle cutout
    canvas.drawCircle(Offset(cx, cy), r * 0.32, paint);
  }

  @override
  bool shouldRepaint(covariant _SettingsIconPainter oldDelegate) => false;
}
