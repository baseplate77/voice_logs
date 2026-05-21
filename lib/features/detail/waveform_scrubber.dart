import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../app_theme.dart';
import '../record/wav_io.dart';
import 'audio_player_controller.dart';

/// Bucketed peak summary used to paint a waveform. Stored as a list of
/// normalized magnitudes in `[0.0, 1.0]`, one entry per render bucket.
class WaveformPeaks {
  WaveformPeaks({required this.peaks, required this.totalMs});

  final List<double> peaks;
  final int totalMs;

  bool get isEmpty => peaks.isEmpty;
}

/// Async load + downsample a PCM16 WAV into [WaveformPeaks]. Reads chunks
/// off disk so it doesn't allocate a buffer the size of the full clip.
Future<WaveformPeaks> loadWaveformPeaks(
  String absolutePath, {
  int bucketCount = 65,
}) async {
  if (bucketCount <= 0) {
    throw ArgumentError.value(bucketCount, 'bucketCount');
  }
  if (!File(absolutePath).existsSync()) {
    return WaveformPeaks(peaks: [], totalMs: 0);
  }
  final info = await readPcm16WavInfo(absolutePath);
  final totalSamples = info.dataBytes ~/ 2;
  if (totalSamples <= 0) {
    return WaveformPeaks(peaks: [], totalMs: 0);
  }
  final samplesPerBucket = (totalSamples / bucketCount).ceil();
  final peaks = Float32List(bucketCount);

  var bucketIdx = 0;
  var consumedInBucket = 0;
  double currentMax = 0;

  await for (final chunk in readPcm16WavFloatChunks(
    absolutePath,
    samplesPerChunk: samplesPerBucket,
  )) {
    for (var i = 0; i < chunk.length; i++) {
      final v = chunk[i].abs();
      if (v > currentMax) currentMax = v;
      consumedInBucket++;
      if (consumedInBucket >= samplesPerBucket) {
        if (bucketIdx < bucketCount) {
          peaks[bucketIdx++] = currentMax;
        }
        currentMax = 0;
        consumedInBucket = 0;
      }
    }
  }
  if (consumedInBucket > 0 && bucketIdx < bucketCount) {
    peaks[bucketIdx++] = currentMax;
  }

  return WaveformPeaks(
    peaks: List<double>.unmodifiable(peaks.take(bucketIdx)),
    totalMs: (totalSamples * 1000) ~/ info.sampleRate,
  );
}

/// Static waveform with a playhead, tap to seek. Drag/swipe is intentionally
/// left out for v1 — tap-to-jump matches the way users move through a
/// transcript word-by-word.
class WaveformScrubber extends StatefulWidget {
  const WaveformScrubber({
    super.key,
    required this.peaks,
    required this.controller,
    this.height = 64,
    this.barColor = VoxAppColors.accent,
    this.playedColor = VoxAppColors.primary,
  });

  final WaveformPeaks peaks;
  final AudioPlayerController controller;
  final double height;
  final Color barColor;
  final Color playedColor;

  @override
  State<WaveformScrubber> createState() => _WaveformScrubberState();
}

class _WaveformScrubberState extends State<WaveformScrubber> {
  StreamSubscription<Duration>? _posSub;
  Duration _position = Duration.zero;

  @override
  void initState() {
    super.initState();
    _posSub = widget.controller.positionStream.listen((p) {
      if (!mounted) return;
      setState(() => _position = p);
    });
  }

  @override
  void dispose() {
    _posSub?.cancel();
    super.dispose();
  }

  void _seekToFraction(double fraction, double maxWidth) {
    final totalMs = widget.peaks.totalMs;
    if (totalMs <= 0) return;
    final clamped = fraction.clamp(0.0, 1.0);
    widget.controller.seek(Duration(milliseconds: (totalMs * clamped).round()));
  }

  @override
  Widget build(BuildContext context) {
    if (widget.peaks.isEmpty) {
      return SizedBox(height: widget.height);
    }
    final totalMs = widget.peaks.totalMs;
    final progress = totalMs <= 0
        ? 0.0
        : (_position.inMilliseconds / totalMs).clamp(0.0, 1.0);
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (details) =>
              _seekToFraction(details.localPosition.dx / width, width),
          child: SizedBox(
            height: widget.height,
            width: double.infinity,
            child: CustomPaint(
              painter: _WaveformPainter(
                peaks: widget.peaks.peaks,
                progress: progress,
                barColor: widget.barColor,
                playedColor: widget.playedColor,
              ),
            ),
          ),
        );
      },
    );
  }
}

class _WaveformPainter extends CustomPainter {
  _WaveformPainter({
    required this.peaks,
    required this.progress,
    required this.barColor,
    required this.playedColor,
  });

  final List<double> peaks;
  final double progress;
  final Color barColor;
  final Color playedColor;

  @override
  void paint(Canvas canvas, Size size) {
    if (peaks.isEmpty) return;
    final barCount = peaks.length;
    final spacing = size.width / barCount;
    final vSpacing = spacing.clamp(4.5, 12.0);
    // Dynamic dot radius based on screen density & spacing
    final dotRadius = (spacing * 0.28).clamp(1.5, 5.0);
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

    final seekX = progress * size.width;

    // 2. Draw the centerline and active amplitude dots
    for (var i = 0; i < barCount; i++) {
      final x = spacing * i + spacing / 2;
      final isPlayed = x < seekX;
      final baseColor = isPlayed ? playedColor : barColor;

      // Centerline dot
      final centerlinePaint = Paint()
        ..color = isPlayed ? playedColor : barColor;
      canvas.drawCircle(Offset(x, mid), dotRadius * 1.1, centerlinePaint);

      // Active amplitude dots
      final level = peaks[i];
      final activeDots = (level * maxDotsPerSide).round().clamp(
        0,
        maxDotsPerSide,
      );

      for (var j = 1; j <= activeDots; j++) {
        double opacity = 1.0 - (j / (maxDotsPerSide + 1)) * 0.7;
        // Remaining (unplayed) dots are soft and faded for elegant contrast
        if (!isPlayed) {
          opacity *= 0.45;
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

    // 3. Draw playhead seek line and center playhead dot
    final seekPaint = Paint()
      ..color = const Color(0xFFE13C30)
      ..strokeWidth = 2.0
      ..style = PaintingStyle.stroke;

    canvas.drawLine(Offset(seekX, 0), Offset(seekX, size.height), seekPaint);

    final dotPaint = Paint()
      ..color = const Color(0xFFE13C30)
      ..style = PaintingStyle.fill;

    canvas.drawCircle(Offset(seekX, mid), 4.5, dotPaint);
  }

  @override
  bool shouldRepaint(_WaveformPainter old) =>
      old.progress != progress ||
      old.peaks != peaks ||
      old.barColor != barColor ||
      old.playedColor != playedColor;
}
