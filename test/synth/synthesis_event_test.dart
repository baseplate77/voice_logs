import 'package:flutter_test/flutter_test.dart';
import 'package:voxsynth/synth/models/synthesis_event.dart';

void main() {
  group('Citation', () {
    test('asserts spanEnd > spanStart', () {
      expect(
        () => Citation(
          tag: 'C1',
          chunkId: 1,
          spanStart: 10,
          spanEnd: 5,
        ),
        throwsA(isA<AssertionError>()),
      );
    });

    test('asserts non-negative spanStart', () {
      expect(
        () => Citation(
          tag: 'C1',
          chunkId: 1,
          spanStart: -1,
          spanEnd: 10,
        ),
        throwsA(isA<AssertionError>()),
      );
    });

    test('equality by every field', () {
      const a = Citation(
        tag: 'C1',
        chunkId: 42,
        spanStart: 5,
        spanEnd: 9,
      );
      const b = Citation(
        tag: 'C1',
        chunkId: 42,
        spanStart: 5,
        spanEnd: 9,
      );
      const c = Citation(
        tag: 'C1',
        chunkId: 42,
        spanStart: 5,
        spanEnd: 10,
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(c));
    });
  });

  group('SynthesisEvent', () {
    test('is a sealed hierarchy covering every subtype', () {
      const events = <SynthesisEvent>[
        RetrievalStarted(),
        RetrievalComplete(chunks: []),
        TokenGenerated(token: 'hi'),
        SynthesisComplete(answer: '', citations: []),
        SynthesisFailed(message: 'oops'),
      ];
      expect(events, hasLength(5));
    });

    test('TokenGenerated carries the token verbatim', () {
      const e = TokenGenerated(token: 'hello');
      expect(e.token, 'hello');
    });

    test('SynthesisComplete carries answer + citations', () {
      const e = SynthesisComplete(
        answer: 'Paris is the capital [C1].',
        citations: <Citation>[
          Citation(tag: 'C1', chunkId: 42, spanStart: 21, spanEnd: 25),
        ],
      );
      expect(e.answer, contains('C1'));
      expect(e.citations, hasLength(1));
    });

    test('SynthesisFailed captures a message + optional cause', () {
      const e = SynthesisFailed(message: 'LLM refused', cause: 'retry exhausted');
      expect(e.message, 'LLM refused');
      expect(e.cause, 'retry exhausted');
    });
  });
}
