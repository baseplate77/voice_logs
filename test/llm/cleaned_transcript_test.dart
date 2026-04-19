import 'package:flutter_test/flutter_test.dart';
import 'package:voxsynth/llm/models/cleaned_transcript.dart';

void main() {
  group('Entity', () {
    test('salience must be in [0, 1]', () {
      expect(
        () => Entity(name: 'x', kind: 'person', salience: 1.5),
        throwsA(isA<AssertionError>()),
      );
      expect(
        () => Entity(name: 'x', kind: 'person', salience: -0.1),
        throwsA(isA<AssertionError>()),
      );
    });

    test('equality is value-based including aliases', () {
      const a = Entity(
        name: 'Alice',
        kind: 'person',
        aliases: <String>['A.'],
      );
      const b = Entity(
        name: 'Alice',
        kind: 'person',
        aliases: <String>['A.'],
      );
      const c = Entity(
        name: 'Alice',
        kind: 'person',
        aliases: <String>['A', '.'],
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(c));
    });
  });

  group('TopicChunk', () {
    test('asserts endChar > startChar', () {
      expect(
        () => TopicChunk(
          text: 'hi',
          startChar: 10,
          endChar: 5,
          topicHint: 'x',
        ),
        throwsA(isA<AssertionError>()),
      );
    });

    test('wordCount counts whitespace-separated tokens', () {
      const c = TopicChunk(
        text: 'one  two three\nfour',
        startChar: 0,
        endChar: 18,
        topicHint: 't',
      );
      expect(c.wordCount, 4);
    });

    test('equality compares all fields including entityRefs', () {
      const a = TopicChunk(
        text: 'x',
        startChar: 0,
        endChar: 1,
        topicHint: 'h',
        entityRefs: <String>['Alice'],
      );
      const b = TopicChunk(
        text: 'x',
        startChar: 0,
        endChar: 1,
        topicHint: 'h',
        entityRefs: <String>['Alice'],
      );
      const c = TopicChunk(
        text: 'x',
        startChar: 0,
        endChar: 1,
        topicHint: 'h',
        entityRefs: <String>['Bob'],
      );
      expect(a, b);
      expect(a, isNot(c));
    });
  });

  group('CleanedTranscript', () {
    test('empty is the canonical null value', () {
      expect(CleanedTranscript.empty.text, '');
      expect(CleanedTranscript.empty.chunks, isEmpty);
      expect(CleanedTranscript.empty.entities, isEmpty);
      expect(CleanedTranscript.empty.tags, isEmpty);
    });

    test('equality deep-compares chunks + entities + tags', () {
      const ct1 = CleanedTranscript(
        text: 'hello world',
        chunks: <TopicChunk>[
          TopicChunk(
            text: 'hello',
            startChar: 0,
            endChar: 5,
            topicHint: 'greeting',
          ),
        ],
        entities: <Entity>[
          Entity(name: 'World', kind: 'concept'),
        ],
        tags: <String>['greeting'],
      );
      const ct2 = CleanedTranscript(
        text: 'hello world',
        chunks: <TopicChunk>[
          TopicChunk(
            text: 'hello',
            startChar: 0,
            endChar: 5,
            topicHint: 'greeting',
          ),
        ],
        entities: <Entity>[
          Entity(name: 'World', kind: 'concept'),
        ],
        tags: <String>['greeting'],
      );
      expect(ct1, ct2);
      expect(ct1.hashCode, ct2.hashCode);
    });

    test('catches a chunk-list mismatch', () {
      const a = CleanedTranscript(
        text: '',
        chunks: <TopicChunk>[],
        entities: <Entity>[],
        tags: <String>['a'],
      );
      const b = CleanedTranscript(
        text: '',
        chunks: <TopicChunk>[],
        entities: <Entity>[],
        tags: <String>['b'],
      );
      expect(a, isNot(b));
    });
  });
}
