import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:voxsynth/capture/models/speech_segment.dart';

void main() {
  group('SpeechSegment', () {
    test('durationMs is endMs - startMs', () {
      final seg = SpeechSegment(
        startMs: 1000,
        endMs: 2500,
        pcm16kMono: Uint8List(1500 * 32),
      );
      expect(seg.durationMs, 1500);
    });

    test('equality compares timestamps and PCM bytes', () {
      final a = SpeechSegment(
        startMs: 0,
        endMs: 100,
        pcm16kMono: Uint8List.fromList(<int>[1, 2, 3, 4]),
      );
      final b = SpeechSegment(
        startMs: 0,
        endMs: 100,
        pcm16kMono: Uint8List.fromList(<int>[1, 2, 3, 4]),
      );
      final c = SpeechSegment(
        startMs: 0,
        endMs: 100,
        pcm16kMono: Uint8List.fromList(<int>[1, 2, 3, 5]),
      );
      expect(a, b);
      expect(a, isNot(c));
    });

    test('asserts endMs >= startMs', () {
      expect(
        () => SpeechSegment(startMs: 500, endMs: 100, pcm16kMono: Uint8List(0)),
        throwsA(isA<AssertionError>()),
      );
    });

    test('toString reports timestamps and byte length', () {
      final seg = SpeechSegment(
        startMs: 10,
        endMs: 20,
        pcm16kMono: Uint8List(8),
      );
      expect(seg.toString(), contains('10..20'));
      expect(seg.toString(), contains('8 bytes'));
    });
  });

  group('RecordingHandle', () {
    test('equality compares all fields', () {
      final now = DateTime.utc(2026, 4, 19, 12);
      final a = RecordingHandle(
        id: 'abc',
        audioFilePath: '/tmp/a.wav',
        durationMs: 30000,
        startedAt: now,
      );
      final b = RecordingHandle(
        id: 'abc',
        audioFilePath: '/tmp/a.wav',
        durationMs: 30000,
        startedAt: now,
      );
      final c = RecordingHandle(
        id: 'abc',
        audioFilePath: '/tmp/a.wav',
        durationMs: 30001,
        startedAt: now,
      );
      expect(a, b);
      expect(a, isNot(c));
    });
  });

  group('CaptureState', () {
    test('has all expected lifecycle values', () {
      expect(CaptureState.values, hasLength(6));
      expect(CaptureState.values, contains(CaptureState.idle));
      expect(CaptureState.values, contains(CaptureState.recording));
      expect(CaptureState.values, contains(CaptureState.error));
    });
  });
}
