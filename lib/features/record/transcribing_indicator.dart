import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Lightweight animated indicator for the high-memory transcription phase.
///
/// Uses one ticker and one custom paint layer instead of a tree of animated
/// widgets. This keeps allocations low while ASR model memory is spiking.
class TranscribingIndicator extends StatefulWidget {
  const TranscribingIndicator({super.key, this.size = 42, this.color});

  /// Square paint size in logical pixels.
  final double size;
  final Color? color;

  @override
  State<TranscribingIndicator> createState() => _TranscribingIndicatorState();
}

class _TranscribingIndicatorState extends State<TranscribingIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(
        milliseconds: 2000,
      ), // Slower, more authentic reel rotation
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Transcribing audio',
      liveRegion: true,
      child: RepaintBoundary(
        child: SizedBox.square(
          dimension: widget.size,
          child: AnimatedBuilder(
            animation: _controller,
            builder: (context, _) => CustomPaint(
              painter: _TranscribingPainter(
                progress: _controller.value,
                color: widget.color ?? Theme.of(context).colorScheme.primary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TranscribingPainter extends CustomPainter {
  _TranscribingPainter({required this.progress, required this.color});

  final double progress;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final maxRadius = math.min(size.width, size.height) / 2;

    // Define the dimensions of our minimal tape reel
    final rimRadius = maxRadius * 0.92;
    final hubRadius = maxRadius * 0.28;
    final tapeRadius = maxRadius * 0.65; // Visual tape layer wound on hub

    // 1. Paint for the outer rim (sleek thin line)
    final rimPaint = Paint()
      ..color = color.withValues(alpha: 0.8)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6;

    // 2. Paint for the tape layer wound on the hub (semi-transparent filled circle)
    final tapePaint = Paint()
      ..color = color.withValues(alpha: 0.12)
      ..style = PaintingStyle.fill;

    // 3. Paint for the central hub (solid fill)
    final hubPaint = Paint()
      ..color = color.withValues(alpha: 0.9)
      ..style = PaintingStyle.fill;

    // 4. Paint for the spokes (thin radial lines)
    final spokePaint = Paint()
      ..color = color.withValues(alpha: 0.85)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round;

    // Draw the elements
    // Draw tape layer
    canvas.drawCircle(center, tapeRadius, tapePaint);

    // Draw outer rim
    canvas.drawCircle(center, rimRadius, rimPaint);

    // Draw central hub
    canvas.drawCircle(center, hubRadius, hubPaint);

    // Draw 3 retro rotating spokes
    final double angleOffset = progress * 2 * math.pi;
    for (int i = 0; i < 3; i++) {
      final double angle = angleOffset + (i * 2 * math.pi / 3);
      final start = Offset(
        center.dx + math.cos(angle) * hubRadius,
        center.dy + math.sin(angle) * hubRadius,
      );
      final end = Offset(
        center.dx + math.cos(angle) * rimRadius,
        center.dy + math.sin(angle) * rimRadius,
      );
      canvas.drawLine(start, end, spokePaint);
    }

    // Draw a small center hole inside the hub for authenticity
    final holePaint = Paint()
      ..color = Colors.black.withValues(alpha: 0.5)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(center, hubRadius * 0.35, holePaint);
  }

  @override
  bool shouldRepaint(covariant _TranscribingPainter oldDelegate) {
    return oldDelegate.progress != progress || oldDelegate.color != color;
  }
}
