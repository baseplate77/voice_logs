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
  const WaveformPeaks({required this.peaks, required this.totalMs});

  final List<double> peaks;
  final int totalMs;

  bool get isEmpty => peaks.isEmpty;
}

/// Async load + downsample a PCM16 WAV into [WaveformPeaks]. Reads chunks
/// off disk so it doesn't allocate a buffer the size of the full clip.
Future<WaveformPeaks> loadWaveformPeaks(
  String absolutePath, {
  int bucketCount = 200,
}) async {
  if (bucketCount <= 0) {
    throw ArgumentError.value(bucketCount, 'bucketCount');
  }
  if (!File(absolutePath).existsSync()) {
    return const WaveformPeaks(peaks: [], totalMs: 0);
  }
  final info = await readPcm16WavInfo(absolutePath);
  final totalSamples = info.dataBytes ~/ 2;
  if (totalSamples <= 0) {
    return const WaveformPeaks(peaks: [], totalMs: 0);
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
    final slotWidth = size.width / barCount;
    final barWidth = (slotWidth * 0.6).clamp(1.0, slotWidth);
    final mid = size.height / 2;
    final playheadIdx = (progress * barCount).floor();

    final unplayed = Paint()..color = barColor;
    final played = Paint()..color = playedColor;

    for (var i = 0; i < barCount; i++) {
      final h = (peaks[i] * size.height).clamp(2.0, size.height);
      final x = slotWidth * i + (slotWidth - barWidth) / 2;
      final rect = Rect.fromLTWH(x, mid - h / 2, barWidth, h);
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(1)),
        i <= playheadIdx ? played : unplayed,
      );
    }
  }

  @override
  bool shouldRepaint(_WaveformPainter old) =>
      old.progress != progress ||
      old.peaks != peaks ||
      old.barColor != barColor ||
      old.playedColor != playedColor;
}
