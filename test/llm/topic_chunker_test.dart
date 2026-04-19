import 'package:flutter_test/flutter_test.dart';
import 'package:voxsynth/llm/topic_chunker.dart';

/// Build a string of N space-separated words: "w0 w1 w2 …".
String _words(int n) => List<String>.generate(n, (i) => 'w$i').join(' ');

void main() {
  const chunker = TopicChunker();

  group('TopicChunker (valid LLM boundaries)', () {
    test('passes through well-formed boundaries verbatim', () {
      final text = '${_words(60)} ${_words(60).replaceAll('w', 'x')}';
      // Split roughly in half. Find the space between the two groups.
      final mid = text.indexOf(' x');
      final proposed = <ProposedBoundary>[
        ProposedBoundary(start: 0, end: mid, topic: 'first'),
        ProposedBoundary(
          start: mid + 1,
          end: text.length,
          topic: 'second',
        ),
      ];
      final result = chunker.chunk(text, proposed);
      expect(result.isFallback, isFalse);
      expect(result.chunks, hasLength(2));
      expect(result.chunks[0].topicHint, 'first');
      expect(result.chunks[1].topicHint, 'second');
    });

    test('empty text yields empty chunk list with no fallback', () {
      final result = chunker.chunk('', null);
      expect(result.chunks, isEmpty);
      expect(result.isFallback, isFalse);
    });
  });

  group('TopicChunker fallback triggers', () {
    test('null boundaries → fallback (empty)', () {
      final text = _words(220);
      final result = chunker.chunk(text, null);
      expect(result.fallbackReason, ChunkingFallbackReason.empty);
      expect(result.chunks, hasLength(2));
      expect(result.chunks.first.topicHint, '(fixed-width fallback)');
    });

    test('empty boundaries → fallback (empty)', () {
      final text = _words(220);
      final result = chunker.chunk(text, const <ProposedBoundary>[]);
      expect(result.fallbackReason, ChunkingFallbackReason.empty);
    });

    test('chunk shorter than 50 words → fallback', () {
      final text = _words(220);
      final proposed = <ProposedBoundary>[
        const ProposedBoundary(start: 0, end: 20, topic: 'tiny'),
        ProposedBoundary(start: 20, end: text.length, topic: 'rest'),
      ];
      final result = chunker.chunk(text, proposed);
      expect(result.fallbackReason, ChunkingFallbackReason.chunkTooShort);
    });

    test('chunk longer than 500 words → fallback', () {
      final text = _words(1000);
      final proposed = <ProposedBoundary>[
        ProposedBoundary(start: 0, end: text.length, topic: 'all'),
      ];
      final result = chunker.chunk(text, proposed);
      expect(result.fallbackReason, ChunkingFallbackReason.chunkTooLong);
    });

    test('out-of-range boundary → fallback', () {
      final text = _words(220);
      final proposed = <ProposedBoundary>[
        ProposedBoundary(start: 0, end: text.length + 100, topic: 'x'),
      ];
      final result = chunker.chunk(text, proposed);
      expect(result.fallbackReason, ChunkingFallbackReason.outOfRange);
    });

    test('overlapping boundaries → fallback', () {
      final text = _words(220);
      final mid = text.length ~/ 2;
      final proposed = <ProposedBoundary>[
        ProposedBoundary(start: 0, end: mid + 10, topic: 'a'),
        ProposedBoundary(start: mid, end: text.length, topic: 'b'),
      ];
      final result = chunker.chunk(text, proposed);
      expect(
        result.fallbackReason,
        anyOf(
          ChunkingFallbackReason.overlap,
          ChunkingFallbackReason.notOrdered,
        ),
      );
    });

    test('boundaries do not cover full text → fallback', () {
      final text = _words(220);
      final proposed = <ProposedBoundary>[
        ProposedBoundary(
          start: 0,
          end: text.length - 50,
          topic: 'partial',
        ),
      ];
      final result = chunker.chunk(text, proposed);
      // Depending on which validation trips first, this could be a word
      // count failure or doesNotCoverText. Either is a correct fallback.
      expect(result.isFallback, isTrue);
    });
  });

  group('Fixed-width fallback chunking', () {
    test('splits into ~200-word chunks', () {
      final text = _words(520);
      final result = chunker.chunk(text, null);
      expect(result.isFallback, isTrue);
      // 520 / 200 = 2 full + remainder of 120 → 3 chunks.
      expect(result.chunks, hasLength(3));
      expect(result.chunks[0].wordCount, 200);
      expect(result.chunks[1].wordCount, 200);
      expect(result.chunks[2].wordCount, 120);
    });

    test('covers the full text end-to-end', () {
      final text = _words(220);
      final result = chunker.chunk(text, null);
      expect(result.chunks.first.startChar, 0);
      expect(result.chunks.last.endChar, text.length);
    });

    test('never splits mid-word', () {
      final text = _words(210);
      final result = chunker.chunk(text, null);
      final wsRe = RegExp(r'\s');
      for (final c in result.chunks) {
        // No chunk text starts or ends with whitespace.
        expect(c.text.startsWith(wsRe), isFalse);
        expect(wsRe.hasMatch(c.text.substring(c.text.length - 1)), isFalse);
      }
    });

    test('tags every chunk with the fallback topicHint', () {
      final text = _words(220);
      final result = chunker.chunk(text, null);
      for (final c in result.chunks) {
        expect(c.topicHint, '(fixed-width fallback)');
      }
    });
  });
}
