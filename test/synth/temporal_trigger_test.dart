import 'package:flutter_test/flutter_test.dart';
import 'package:voxsynth/synth/temporal_trigger.dart';

void main() {
  group('isTemporalQuery', () {
    test('false for empty / whitespace-only queries', () {
      expect(isTemporalQuery(''), isFalse);
      expect(isTemporalQuery('   '), isFalse);
      expect(isTemporalQuery('\t\n'), isFalse);
    });

    test('false for plain factual queries', () {
      expect(isTemporalQuery('what is the capital of France'), isFalse);
      expect(isTemporalQuery('GlowUp pricing decision'), isFalse);
      expect(isTemporalQuery('who is Alice'), isFalse);
    });

    test('true for evolution-style queries', () {
      expect(isTemporalQuery('how has the pricing evolved'), isTrue);
      expect(isTemporalQuery('what has changed with Alice'), isTrue);
      expect(isTemporalQuery('how the project has changed over time'), isTrue);
      expect(
        isTemporalQuery('pricing trajectory across the last quarter'),
        isTrue,
      );
    });

    test('true for relative-time-window queries', () {
      expect(isTemporalQuery('what did I say this week'), isTrue);
      expect(isTemporalQuery('decisions this month'), isTrue);
      expect(isTemporalQuery('last week meetings'), isTrue);
      expect(isTemporalQuery('what happened lately'), isTrue);
      expect(isTemporalQuery('what did we discuss recently'), isTrue);
    });

    test('case-insensitive matching', () {
      expect(isTemporalQuery('HOW HAS pricing CHANGED'), isTrue);
      expect(isTemporalQuery('This Week'), isTrue);
    });

    test('every documented keyword triggers', () {
      for (final kw in kTemporalKeywords) {
        expect(
          isTemporalQuery('wrapping $kw in noise'),
          isTrue,
          reason: 'keyword "$kw" did not trigger',
        );
      }
    });

    test('does not false-positive on partial substrings', () {
      // "trendy" contains "trend" → this IS a false positive we accept
      // (keyword classifier is intentionally simple). But "last" alone
      // without "last week/month" should not trigger.
      expect(isTemporalQuery('the last option is X'), isFalse);
      expect(isTemporalQuery('this is just a casual query'), isFalse);
    });

    test('trendy/changed contribute false-positives by design', () {
      // Document the known gap so we don't regress into over-tuning.
      expect(isTemporalQuery('a trendy café'), isTrue);
      expect(isTemporalQuery('changing clothes'), isTrue);
    });
  });
}
