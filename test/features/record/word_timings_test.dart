import 'package:flutter_test/flutter_test.dart';
import 'package:voxsynth/features/record/parakeet_runner.dart';
import 'package:voxsynth/features/record/speech_recognizer.dart';

void main() {
  group('reconstructWordsFromTokens', () {
    test('returns empty list when there are no tokens', () {
      final words = reconstructWordsFromTokens(
        tokens: const [],
        timestampsSeconds: const [],
        chunkOffsetMs: 0,
        chunkEndMs: 30000,
      );
      expect(words, isEmpty);
    });

    test('groups SentencePiece subwords into single words', () {
      // "▁hello ▁world" — two words, four tokens including a continuation.
      final words = reconstructWordsFromTokens(
        tokens: const ['▁hel', 'lo', '▁world'],
        timestampsSeconds: const [0.10, 0.20, 0.45],
        chunkOffsetMs: 0,
        chunkEndMs: 1000,
      );
      expect(words, hasLength(2));
      expect(words[0].word, 'hello');
      expect(words[0].startMs, 100);
      expect(words[0].endMs, 450); // end = next word's start
      expect(words[1].word, 'world');
      expect(words[1].startMs, 450);
      expect(words[1].endMs, 1000); // end = chunk end for last word
    });

    test('applies chunk offset to timestamps', () {
      final words = reconstructWordsFromTokens(
        tokens: const ['▁one', '▁two'],
        timestampsSeconds: const [0.05, 0.30],
        chunkOffsetMs: 30000,
        chunkEndMs: 60000,
      );
      expect(words, hasLength(2));
      expect(words[0].startMs, 30050);
      expect(words[1].startMs, 30300);
      expect(words[1].endMs, 60000);
    });

    test('skips blank/special tokens', () {
      final words = reconstructWordsFromTokens(
        tokens: const ['<blk>', '▁ok', '<unk>', '▁go'],
        timestampsSeconds: const [0.0, 0.10, 0.15, 0.40],
        chunkOffsetMs: 0,
        chunkEndMs: 1000,
      );
      expect(words.map((w) => w.word).toList(), ['ok', 'go']);
    });

    test('starts a word even without a boundary marker on the first token', () {
      // Defensive: if the first decoded token lacks the SentencePiece prefix
      // we still want to surface it rather than drop it on the floor.
      final words = reconstructWordsFromTokens(
        tokens: const ['hello', '▁world'],
        timestampsSeconds: const [0.0, 0.30],
        chunkOffsetMs: 0,
        chunkEndMs: 1000,
      );
      expect(words.map((w) => w.word).toList(), ['hello', 'world']);
    });
  });

  group('encode/decodeWordTimings', () {
    test('roundtrips a non-empty list of words', () {
      const words = [
        WordTiming(word: 'one', startMs: 0, endMs: 200),
        WordTiming(word: 'two', startMs: 200, endMs: 500),
      ];
      final encoded = encodeWordTimings(words);
      expect(encoded, isNotNull);
      final decoded = decodeWordTimings(encoded);
      expect(decoded, hasLength(2));
      expect(decoded[0].word, 'one');
      expect(decoded[1].endMs, 500);
    });

    test('encodes empty list as null', () {
      expect(encodeWordTimings(const []), isNull);
      expect(decodeWordTimings(null), isEmpty);
      expect(decodeWordTimings(''), isEmpty);
    });
  });
}
