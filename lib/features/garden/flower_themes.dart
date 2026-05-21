import 'dart:math' as math;
import 'package:flutter/material.dart';

/// The 7 distinct minimalist flower classifications mapped from voice logs.
enum FlowerType {
  sakura,
  lavender,
  cactus,
  sunflower,
  fern,
  mushroom,
  rose,
}

extension FlowerTypeExtension on FlowerType {
  String get id => name;

  String get displayName => switch (this) {
        FlowerType.sakura => 'Sakura',
        FlowerType.lavender => 'Lavender',
        FlowerType.cactus => 'Cactus',
        FlowerType.sunflower => 'Sunflower',
        FlowerType.fern => 'Fern',
        FlowerType.mushroom => 'Mushroom',
        FlowerType.rose => 'Rose',
      };

  String get vibe => switch (this) {
        FlowerType.sakura => 'Joy & Optimism',
        FlowerType.lavender => 'Peace & Calm',
        FlowerType.cactus => 'Stress & Resilience',
        FlowerType.sunflower => 'Energy & Focus',
        FlowerType.fern => 'Growth & Introspection',
        FlowerType.mushroom => 'Creative Musings',
        FlowerType.rose => 'Love & Connection',
      };

  String get description => switch (this) {
        FlowerType.sakura => 'Representing joy, happiness, positive wins, and gratitude.',
        FlowerType.lavender => 'Representing peace, quiet reflection, rest, and mindfulness.',
        FlowerType.cactus => 'Representing stress relief, heavy workloads, and resilience.',
        FlowerType.sunflower => 'Representing productivity, heavy workouts, planning, and focus.',
        FlowerType.fern => 'Representing learning, introspection, reading, and self-growth.',
        FlowerType.mushroom => 'Representing shower thoughts, creative ideas, and dream diaries.',
        FlowerType.rose => 'Representing family warmth, romantic notes, and social appreciation.',
      };

  Color get color => const Color(0xFF3F51B5); // Sleek retro cobalt blue
  Color get accentColor => const Color(0xFFFF3B30); // Vibrant red dot accent

  /// Paint the flower's vector path and red-dot accent on the canvas.
  void paint(
    Canvas canvas,
    Offset center,
    double size,
    Paint strokePaint,
    Paint accentPaint,
  ) {
    // Keep stroke paint clean and crisp
    strokePaint
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(1.2, size * 0.08)
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    accentPaint
      ..color = accentColor
      ..style = PaintingStyle.fill;

    switch (this) {
      case FlowerType.sakura:
        _paintSakura(canvas, center, size, strokePaint, accentPaint);
      case FlowerType.lavender:
        _paintLavender(canvas, center, size, strokePaint, accentPaint);
      case FlowerType.cactus:
        _paintCactus(canvas, center, size, strokePaint, accentPaint);
      case FlowerType.sunflower:
        _paintSunflower(canvas, center, size, strokePaint, accentPaint);
      case FlowerType.fern:
        _paintFern(canvas, center, size, strokePaint, accentPaint);
      case FlowerType.mushroom:
        _paintMushroom(canvas, center, size, strokePaint, accentPaint);
      case FlowerType.rose:
        _paintRose(canvas, center, size, strokePaint, accentPaint);
    }
  }

  void _paintSakura(
    Canvas canvas,
    Offset center,
    double size,
    Paint strokePaint,
    Paint accentPaint,
  ) {
    final r = size * 0.35;
    // Draw 5 petals
    for (var i = 0; i < 5; i++) {
      final angle = (i * 2 * math.pi / 5) - math.pi / 2;
      final petalCenter = Offset(
        center.dx + r * math.cos(angle),
        center.dy + r * math.sin(angle),
      );
      
      // Paint an elegant simple petal outline
      canvas.drawCircle(petalCenter, size * 0.16, strokePaint);
    }
    
    // Core vibrant red dot
    canvas.drawCircle(center, size * 0.12, accentPaint);
  }

  void _paintLavender(
    Canvas canvas,
    Offset center,
    double size,
    Paint strokePaint,
    Paint accentPaint,
  ) {
    // Stem
    canvas.drawLine(
      Offset(center.dx, center.dy + size * 0.45),
      Offset(center.dx, center.dy - size * 0.25),
      strokePaint,
    );

    // Blossom beads
    final beadRadius = size * 0.08;
    final heights = [
      center.dy + size * 0.15,
      center.dy,
      center.dy - size * 0.15,
    ];

    for (final h in heights) {
      // Left and right leaf beads
      canvas.drawCircle(Offset(center.dx - size * 0.16, h), beadRadius, strokePaint);
      canvas.drawCircle(Offset(center.dx + size * 0.16, h), beadRadius, strokePaint);
    }

    // Topmost single red dot bud
    canvas.drawCircle(
      Offset(center.dx, center.dy - size * 0.35),
      size * 0.09,
      accentPaint,
    );
  }

  void _paintCactus(
    Canvas canvas,
    Offset center,
    double size,
    Paint strokePaint,
    Paint accentPaint,
  ) {
    final w = size * 0.22;
    final h = size * 0.6;
    
    // Main stem
    final mainRect = RRect.fromRectAndRadius(
      Rect.fromCenter(
        center: Offset(center.dx, center.dy + size * 0.1),
        width: w,
        height: h,
      ),
      Radius.circular(w / 2),
    );
    canvas.drawRRect(mainRect, strokePaint);

    // Left arm
    final leftPath = Path()
      ..moveTo(center.dx - w / 2, center.dy + size * 0.15)
      ..quadraticBezierTo(
        center.dx - size * 0.35,
        center.dy + size * 0.15,
        center.dx - size * 0.35,
        center.dy - size * 0.1,
      );
    canvas.drawPath(leftPath, strokePaint);

    // Right arm
    final rightPath = Path()
      ..moveTo(center.dx + w / 2, center.dy)
      ..quadraticBezierTo(
        center.dx + size * 0.35,
        center.dy,
        center.dx + size * 0.35,
        center.dy - size * 0.2,
      );
    canvas.drawPath(rightPath, strokePaint);

    // Vibrant red flower dot on top
    canvas.drawCircle(
      Offset(center.dx, center.dy - h / 2 + size * 0.1),
      size * 0.1,
      accentPaint,
    );
  }

  void _paintSunflower(
    Canvas canvas,
    Offset center,
    double size,
    Paint strokePaint,
    Paint accentPaint,
  ) {
    final coreR = size * 0.18;
    // Core center outline
    canvas.drawCircle(center, coreR, strokePaint);

    // Radiating petals
    const petalCount = 8;
    final innerR = coreR + 1;
    final outerR = size * 0.42;

    for (var i = 0; i < petalCount; i++) {
      final angle = i * 2 * math.pi / petalCount;
      final start = Offset(
        center.dx + innerR * math.cos(angle),
        center.dy + innerR * math.sin(angle),
      );
      final end = Offset(
        center.dx + outerR * math.cos(angle),
        center.dy + outerR * math.sin(angle),
      );
      canvas.drawLine(start, end, strokePaint);
      
      // Little dot at the end of each petal
      canvas.drawCircle(end, size * 0.04, strokePaint..style = PaintingStyle.fill);
    }
    
    // Restore stroke style
    strokePaint.style = PaintingStyle.stroke;

    // Vibrant red seed dot in the middle
    canvas.drawCircle(center, size * 0.08, accentPaint);
  }

  void _paintFern(
    Canvas canvas,
    Offset center,
    double size,
    Paint strokePaint,
    Paint accentPaint,
  ) {
    // Elegant curved spine path
    final path = Path()
      ..moveTo(center.dx - size * 0.25, center.dy + size * 0.4)
      ..cubicTo(
        center.dx - size * 0.1,
        center.dy + size * 0.1,
        center.dx + size * 0.1,
        center.dy - size * 0.1,
        center.dx + size * 0.25,
        center.dy - size * 0.3,
      );
    canvas.drawPath(path, strokePaint);

    // Branching leaves
    final leafPositions = [
      (0.2, size * 0.16, -math.pi / 4),
      (0.4, size * 0.22, -math.pi / 4),
      (0.6, size * 0.20, -math.pi / 4),
      (0.8, size * 0.14, -math.pi / 4),
    ];

    for (final leaf in leafPositions) {
      final t = leaf.$1;
      final len = leaf.$2;
      
      // Estimate position along spine
      final x = center.dx - size * 0.25 + (size * 0.5 * t);
      final y = center.dy + size * 0.4 - (size * 0.7 * t);
      
      // Draw left leaf
      canvas.drawLine(
        Offset(x, y),
        Offset(x - len * 0.8, y + len * 0.2),
        strokePaint,
      );
      // Draw right leaf
      canvas.drawLine(
        Offset(x, y),
        Offset(x + len * 0.2, y - len * 0.8),
        strokePaint,
      );
    }

    // Single red dot at the tip of the fern
    canvas.drawCircle(
      Offset(center.dx + size * 0.25, center.dy - size * 0.3),
      size * 0.09,
      accentPaint,
    );
  }

  void _paintMushroom(
    Canvas canvas,
    Offset center,
    double size,
    Paint strokePaint,
    Paint accentPaint,
  ) {
    final capW = size * 0.8;
    final capH = size * 0.4;
    
    // Stem
    canvas.drawLine(
      Offset(center.dx, center.dy + size * 0.1),
      Offset(center.dx, center.dy + size * 0.45),
      strokePaint,
    );

    // Cap path (semi-circle dome)
    final capPath = Path()
      ..moveTo(center.dx - capW / 2, center.dy + size * 0.1)
      ..quadraticBezierTo(
        center.dx - capW / 2,
        center.dy - capH,
        center.dx,
        center.dy - capH,
      )
      ..quadraticBezierTo(
        center.dx + capW / 2,
        center.dy - capH,
        center.dx + capW / 2,
        center.dy + size * 0.1,
      )
      ..close();
    canvas.drawPath(capPath, strokePaint);

    // Dotted patterns on the mushroom cap
    canvas.drawCircle(Offset(center.dx - size * 0.18, center.dy - size * 0.1), size * 0.05, strokePaint..style = PaintingStyle.fill);
    canvas.drawCircle(Offset(center.dx + size * 0.18, center.dy - size * 0.15), size * 0.05, strokePaint);
    
    // Restore stroke style
    strokePaint.style = PaintingStyle.stroke;

    // Vibrant red dot accent spot
    canvas.drawCircle(
      Offset(center.dx, center.dy - size * 0.22),
      size * 0.08,
      accentPaint,
    );
  }

  void _paintRose(
    Canvas canvas,
    Offset center,
    double size,
    Paint strokePaint,
    Paint accentPaint,
  ) {
    // Center spiral/nested geometric circles
    canvas.drawCircle(center, size * 0.32, strokePaint);
    canvas.drawCircle(center, size * 0.20, strokePaint);
    
    // Small bottom leaf stem
    final leafStem = Path()
      ..moveTo(center.dx, center.dy + size * 0.32)
      ..quadraticBezierTo(
        center.dx - size * 0.1,
        center.dy + size * 0.4,
        center.dx - size * 0.2,
        center.dy + size * 0.45,
      );
    canvas.drawPath(leafStem, strokePaint);

    // Red dot at the very heart of the rose
    canvas.drawCircle(center, size * 0.09, accentPaint);
  }
}
