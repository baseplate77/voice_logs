import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Lightweight animated indicator for the high-memory transcription phase.
///
/// Uses one ticker and one custom paint layer instead of a tree of animated
/// widgets. This keeps allocations low while ASR model memory is spiking.
class TranscribingIndicator extends StatefulWidget {
  const TranscribingIndicator({super.key, this.size = 42});

  /// Square paint size in logical pixels.
  final double size;

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
      duration: const Duration(milliseconds: 900),
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
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TranscribingPainter extends CustomPainter {
  const _TranscribingPainter({required this.progress, required this.color});

  final double progress;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    final centerY = size.height / 2;
    final radius = size.width * 0.095;
    final gap = size.width * 0.22;
    final startX = (size.width - gap * 2) / 2;

    for (var i = 0; i < 3; i++) {
      final phase = (progress + i * 0.18) % 1.0;
      final wave = (math.sin(phase * math.pi * 2) + 1) / 2;
      final scale = 0.72 + wave * 0.55;
      final opacity = 0.35 + wave * 0.65;
      paint.color = color.withValues(alpha: opacity);
      canvas.drawCircle(
        Offset(startX + gap * i, centerY),
        radius * scale,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _TranscribingPainter oldDelegate) {
    return oldDelegate.progress != progress || oldDelegate.color != color;
  }
}
