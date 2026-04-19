import 'package:flutter_test/flutter_test.dart';
import 'package:voxsynth/asr/models/transcript.dart';

void main() {
  group('Word', () {
    test('durationMs is endMs - startMs', () {
      const w = Word(text: 'hi', startMs: 100, endMs: 400, confidence: 0.9);
      expect(w.durationMs, 300);
    });

    test('asserts endMs >= startMs', () {
      expect(
        () => Word(text: 'x', startMs: 10, endMs: 5, confidence: 0.5),
        throwsA(isA<AssertionError>()),
      );
    });

    test('asserts confidence in [0, 1]', () {
      expect(
        () => Word(text: 'x', startMs: 0, endMs: 1, confidence: 1.5),
        throwsA(isA<AssertionError>()),
      );
      expect(
        () => Word(text: 'x', startMs: 0, endMs: 1, confidence: -0.1),
        throwsA(isA<AssertionError>()),
      );
    });

    test('equality by all fields', () {
      const a = Word(text: 'hi', startMs: 0, endMs: 100, confidence: 0.8);
      const b = Word(text: 'hi', startMs: 0, endMs: 100, confidence: 0.8);
      const c = Word(text: 'HI', startMs: 0, endMs: 100, confidence: 0.8);
      const d = Word(text: 'hi', startMs: 0, endMs: 100, confidence: 0.9);
      expect(a, b);
      expect(a, isNot(c));
      expect(a, isNot(d));
    });
  });

  group('Transcript', () {
    test('equality deep-compares words', () {
      const words = <Word>[
        Word(text: 'a', startMs: 0, endMs: 100, confidence: 0.9),
        Word(text: 'b', startMs: 100, endMs: 200, confidence: 0.8),
      ];
      const t1 = Transcript(
        text: 'a b',
        words: words,
        detectedLanguage: 'en',
      );
      const t2 = Transcript(
        text: 'a b',
        words: words,
        detectedLanguage: 'en',
      );
      expect(t1, t2);
      expect(t1.hashCode, t2.hashCode);
    });

    test('empty is the canonical null transcript', () {
      expect(Transcript.empty.text, '');
      expect(Transcript.empty.words, isEmpty);
      expect(Transcript.empty.detectedLanguage, 'en');
    });

    test('differs from a non-empty transcript', () {
      const t = Transcript(
        text: 'hi',
        words: <Word>[
          Word(text: 'hi', startMs: 0, endMs: 100, confidence: 1.0),
        ],
        detectedLanguage: 'en',
      );
      expect(t, isNot(Transcript.empty));
    });

    test('word count differences are caught', () {
      const a = Transcript(
        text: 'x y',
        words: <Word>[
          Word(text: 'x', startMs: 0, endMs: 100, confidence: 1.0),
          Word(text: 'y', startMs: 100, endMs: 200, confidence: 1.0),
        ],
        detectedLanguage: 'en',
      );
      const b = Transcript(
        text: 'x y',
        words: <Word>[
          Word(text: 'x', startMs: 0, endMs: 100, confidence: 1.0),
        ],
        detectedLanguage: 'en',
      );
      expect(a, isNot(b));
    });
  });
}
