import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:voxsynth/capture/models/speech_segment.dart';
import 'package:voxsynth/capture/vad_segmenter.dart';

/// One 512-sample frame at 16 kHz = 32 ms = 1024 bytes of s16le PCM.
const int _frameSamples = 512;
const int _frameBytes = _frameSamples * 2;
const int _frameMs = 32;

/// Build a PCM buffer with all samples set to [value]. The value itself is
/// meaningless for these tests — they only inspect byte counts.
Uint8List _framePcm({int value = 0}) =>
    Uint8List.fromList(List<int>.filled(_frameBytes, value));

void main() {
  group('VadSegmenter', () {
    test('never emits for pure silence', () {
      final seg = VadSegmenter();
      for (var i = 0; i < 100; i++) {
        expect(seg.feed(probability: 0.0, framePcmBytes: _framePcm()), isNull);
      }
      expect(seg.flush(), isNull);
    });

    test('drops a speech burst shorter than minSpeechDuration', () {
      final seg = VadSegmenter();
      // 300 ms threshold ÷ 32 ms/frame ≈ 10 frames. Give it 5 voiced frames
      // (160 ms) followed by enough silence to close.
      for (var i = 0; i < 5; i++) {
        expect(seg.feed(probability: 0.9, framePcmBytes: _framePcm()), isNull);
      }
      SpeechSegment? emitted;
      for (var i = 0; i < 20; i++) {
        emitted ??= seg.feed(probability: 0.0, framePcmBytes: _framePcm());
      }
      expect(emitted, isNull, reason: 'burst < 300 ms must be dropped');
    });

    test('emits a segment for sustained speech followed by silence', () {
      final seg = VadSegmenter();
      // 15 voiced frames ≈ 480 ms (> 300 ms).
      for (var i = 0; i < 15; i++) {
        expect(seg.feed(probability: 0.95, framePcmBytes: _framePcm()), isNull);
      }
      // Then silence until the 500 ms threshold closes the segment.
      SpeechSegment? emitted;
      for (var i = 0; i < 20; i++) {
        emitted ??= seg.feed(probability: 0.0, framePcmBytes: _framePcm());
        if (emitted != null) break;
      }
      expect(emitted, isNotNull);
      expect(emitted!.startMs, 0);
      expect(emitted.endMs, 15 * _frameMs);
      // PCM should cover exactly 15 frames of voiced audio (silence trimmed).
      expect(emitted.pcm16kMono.length, 15 * _frameBytes);
    });

    test('bridges pauses shorter than minSilenceDuration', () {
      final seg = VadSegmenter();
      // Pattern: 10 voiced, 10 silence (320 ms < 500 ms → bridge),
      // 10 voiced, then 20 silence (640 ms → close).
      for (var i = 0; i < 10; i++) {
        seg.feed(probability: 0.9, framePcmBytes: _framePcm());
      }
      for (var i = 0; i < 10; i++) {
        seg.feed(probability: 0.0, framePcmBytes: _framePcm());
      }
      for (var i = 0; i < 10; i++) {
        seg.feed(probability: 0.9, framePcmBytes: _framePcm());
      }
      SpeechSegment? emitted;
      for (var i = 0; i < 30; i++) {
        emitted ??= seg.feed(probability: 0.0, framePcmBytes: _framePcm());
        if (emitted != null) break;
      }
      expect(emitted, isNotNull);
      expect(emitted!.startMs, 0);
      // Segment should span from frame 0 through end of second voiced block
      // (frame 30 = 960 ms), i.e. 30 frames including the bridged pause.
      expect(emitted.endMs, 30 * _frameMs);
      // PCM must include the bridged silence (30 frames worth of bytes).
      expect(emitted.pcm16kMono.length, 30 * _frameBytes);
    });

    test('emits two segments separated by long silence', () {
      final seg = VadSegmenter();
      final emitted = <SpeechSegment>[];

      void drive({required double prob, required int frames}) {
        for (var i = 0; i < frames; i++) {
          final s = seg.feed(probability: prob, framePcmBytes: _framePcm());
          if (s != null) emitted.add(s);
        }
      }

      drive(prob: 0.9, frames: 15); // 480 ms speech
      drive(prob: 0.0, frames: 20); // 640 ms silence → closes first segment
      drive(prob: 0.9, frames: 15); // another 480 ms speech
      drive(prob: 0.0, frames: 20); // 640 ms silence → closes second segment

      expect(emitted, hasLength(2));
      expect(emitted[0].startMs, 0);
      expect(emitted[0].endMs, 15 * _frameMs);
      // Second segment starts right after the silence that closed the first.
      // Silence bridge: 16 frames to reach 500 ms threshold → first segment
      // closes at that point; remaining 4 silence frames + 15 voiced frames
      // position the second segment's start.
      expect(emitted[1].startMs, greaterThan(emitted[0].endMs));
      expect(emitted[1].endMs - emitted[1].startMs, 15 * _frameMs);
    });

    test('flush emits a trailing segment if still in speech', () {
      final seg = VadSegmenter();
      for (var i = 0; i < 15; i++) {
        seg.feed(probability: 0.9, framePcmBytes: _framePcm());
      }
      final flushed = seg.flush();
      expect(flushed, isNotNull);
      expect(flushed!.startMs, 0);
      expect(flushed.endMs, 15 * _frameMs);
    });

    test('flush drops in-flight segment shorter than minSpeechDuration', () {
      final seg = VadSegmenter();
      for (var i = 0; i < 5; i++) {
        seg.feed(probability: 0.9, framePcmBytes: _framePcm());
      }
      expect(seg.flush(), isNull);
    });

    test('reset clears all state', () {
      final seg = VadSegmenter();
      for (var i = 0; i < 20; i++) {
        seg.feed(probability: 0.9, framePcmBytes: _framePcm());
      }
      seg.reset();
      // After reset a fresh segment starts at 0 again.
      for (var i = 0; i < 15; i++) {
        seg.feed(probability: 0.9, framePcmBytes: _framePcm());
      }
      SpeechSegment? emitted;
      for (var i = 0; i < 20; i++) {
        emitted ??= seg.feed(probability: 0.0, framePcmBytes: _framePcm());
        if (emitted != null) break;
      }
      expect(emitted, isNotNull);
      expect(emitted!.startMs, 0);
    });

    test('threshold inclusive at kSpeechThreshold', () {
      final seg = VadSegmenter();
      // Exactly 0.5 counts as voiced.
      for (var i = 0; i < 15; i++) {
        seg.feed(probability: kSpeechThreshold, framePcmBytes: _framePcm());
      }
      SpeechSegment? emitted;
      for (var i = 0; i < 20; i++) {
        emitted ??= seg.feed(probability: 0.0, framePcmBytes: _framePcm());
        if (emitted != null) break;
      }
      expect(emitted, isNotNull);
    });
  });
}
