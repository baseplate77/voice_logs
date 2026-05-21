import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../core/db/repositories/voice_log_repository.dart';
import 'flower_themes.dart';

/// Custom Painter for the retro-minimalist VoxGarden contribution matrix.
class GardenPainter extends CustomPainter {
  GardenPainter({
    required this.logsByDate,
    required this.startDate,
    required this.animationValue,
    required this.newlyProcessedDate,
    required this.selectedDate,
  });

  /// Map of logs grouped by normalized date (year, month, day).
  final Map<DateTime, VoiceLogView> logsByDate;

  /// The starting Sunday of the 53-week grid.
  final DateTime startDate;

  /// Animation progress for the blooming micro-animation.
  final double animationValue;

  /// Date of a log that has just completed processing to trigger the bloom.
  final DateTime? newlyProcessedDate;

  /// Currently selected/tapped cell date for highlighting.
  final DateTime? selectedDate;

  @override
  void paint(Canvas canvas, Size size) {
    const columns = 53;
    const rows = 7;

    final cellWidth = size.width / columns;
    final cellHeight = size.height / rows;
    final cellSize = math.min(cellWidth, cellHeight);

    final dotPaint = Paint()
      ..color = const Color(0xFFD1D5DB) // Gentle light grey for empty days
      ..style = PaintingStyle.fill;

    final strokePaint = Paint();
    final accentPaint = Paint();

    for (var col = 0; col < columns; col++) {
      for (var row = 0; row < rows; row++) {
        // Calculate date for this matrix cell
        final dayOffset = col * 7 + row;
        final cellDate = startDate.add(Duration(days: dayOffset));
        final normalizedCellDate = DateTime(cellDate.year, cellDate.month, cellDate.day);

        // Center coordinates of this cell
        final cx = col * cellWidth + cellWidth / 2;
        final cy = row * cellHeight + cellHeight / 2;
        final cellCenter = Offset(cx, cy);

        // Highlight selected cell
        if (selectedDate != null &&
            selectedDate!.year == normalizedCellDate.year &&
            selectedDate!.month == normalizedCellDate.month &&
            selectedDate!.day == normalizedCellDate.day) {
          final highlightPaint = Paint()
            ..color = const Color(0xFF3F51B5).withValues(alpha: 0.08)
            ..style = PaintingStyle.fill;
          canvas.drawCircle(cellCenter, cellSize * 0.7, highlightPaint);
          
          final borderPaint = Paint()
            ..color = const Color(0xFF3F51B5).withValues(alpha: 0.3)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.0;
          canvas.drawCircle(cellCenter, cellSize * 0.7, borderPaint);
        }

        final log = logsByDate[normalizedCellDate];
        if (log != null) {
          final flowerType = _parseFlowerType(log.flowerType);
          
          // Size and scale calculations (with optional blooming animation)
          var scale = 1.0;
          final isBlooming = newlyProcessedDate != null &&
              newlyProcessedDate!.year == normalizedCellDate.year &&
              newlyProcessedDate!.month == normalizedCellDate.month &&
              newlyProcessedDate!.day == normalizedCellDate.day;

          if (isBlooming) {
            // Apply elastic organic scale-up
            scale = Curves.elasticOut.transform(animationValue);
            
            // Draw retro particle bursts to celebrate the log refined
            if (animationValue > 0 && animationValue < 1.0) {
              final t = animationValue;
              final particlePaint = Paint()
                ..color = const Color(0xFFFF3B30).withValues(alpha: (1.0 - t).clamp(0.0, 1.0))
                ..style = PaintingStyle.fill;
              
              const numParticles = 8;
              for (var i = 0; i < numParticles; i++) {
                final angle = i * 2 * math.pi / numParticles;
                final dist = cellSize * 0.95 * t;
                final pCenter = Offset(
                  cx + dist * math.cos(angle),
                  cy + dist * math.sin(angle),
                );
                canvas.drawCircle(pCenter, cellSize * 0.08 * (1.0 - t), particlePaint);
              }
            }
          }

          if (scale > 0) {
            canvas.save();
            canvas.translate(cx, cy);
            canvas.scale(scale);
            
            // Paint the line-art flower
            flowerType.paint(
              canvas,
              Offset.zero,
              cellSize * 0.85,
              strokePaint,
              accentPaint,
            );
            
            canvas.restore();
          }
        } else {
          // Draw standard retro-minimalist empty dot
          canvas.drawCircle(cellCenter, 1.8, dotPaint);
        }
      }
    }
  }

  FlowerType _parseFlowerType(String? raw) {
    if (raw == null) return FlowerType.sakura;
    final normalized = raw.trim().toLowerCase();
    for (final type in FlowerType.values) {
      if (type.name == normalized) return type;
    }
    return FlowerType.sakura;
  }

  @override
  bool shouldRepaint(covariant GardenPainter oldDelegate) {
    return oldDelegate.logsByDate != logsByDate ||
        oldDelegate.startDate != startDate ||
        oldDelegate.animationValue != animationValue ||
        oldDelegate.newlyProcessedDate != newlyProcessedDate ||
        oldDelegate.selectedDate != selectedDate;
  }
}
