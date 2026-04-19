import 'package:flutter_test/flutter_test.dart';
import 'package:voxsynth/asr/models/transcript.dart';
import 'package:voxsynth/llm/cleanup_pipeline.dart';
import 'package:voxsynth/llm/llm_runner.dart';

/// Helpful canned LLM responses for the four pipeline steps.
const String _cleanedText =
    'Today we finalised the pricing model for GlowUp. '
    'Alice and Bob agreed to a tiered plan. '
    'We decided to launch pricing in Q3.';

String _repeat(String s, int n) => List<String>.filled(n, s).join(' ');

Transcript _rawTranscript(String text) =>
    Transcript(text: text, words: const <Word>[], detectedLanguage: 'en');

void main() {
  group('CleanupPipeline (happy path)', () {
    test('empty transcript short-circuits to empty CleanedTranscript',
        () async {
      final runner = FakeLlmRunner();
      await runner.load();
      final pipeline = CleanupPipeline(runner: runner);

      final result = await pipeline.clean(_rawTranscript(''));
      expect(result.isOk, isTrue);
      expect(result.okOrNull, const CleanedTranscriptMatch(text: ''));
      // Runner must not be called at all.
      expect(runner.callCount, 0);
    });

    test('populates text, chunks (fallback), entities, tags', () async {
      // Need at least 60 words of cleanup output to survive chunker's
      // 50-word minimum — we repeat a sentence enough times.
      final cleaned = _repeat(_cleanedText, 4);
      final runner = FakeLlmRunner(
        responses: <String>[
          cleaned, // step 1: cleanup
          '[]', // step 2: boundaries (empty → fixed-width fallback)
          '[{"name":"Alice","kind":"person","aliases":[],"salience":0.8},{"name":"Bob","kind":"person","aliases":[],"salience":0.6}]',
          '["pricing","q3"]',
        ],
      );
      await runner.load();
      final pipeline = CleanupPipeline(runner: runner);

      final result = await pipeline.clean(_rawTranscript('um whatever'));
      expect(result.isOk, isTrue);
      final ct = result.okOrNull!;
      expect(ct.text, cleaned);
      expect(ct.chunks, isNotEmpty);
      expect(ct.chunks.first.topicHint, '(fixed-width fallback)');
      expect(ct.entities, hasLength(2));
      expect(ct.entities.first.name, 'Alice');
      expect(ct.tags, <String>['pricing', 'q3']);
    });

    test('strips markdown code fences around JSON output', () async {
      final cleaned = _repeat(_cleanedText, 4);
      final runner = FakeLlmRunner(
        responses: <String>[
          cleaned,
          '```json\n[]\n```',
          '```\n[{"name":"Alice","kind":"person","aliases":[],"salience":0.9}]\n```',
          '```json\n["x"]\n```',
        ],
      );
      await runner.load();
      final pipeline = CleanupPipeline(runner: runner);
      final ct = (await pipeline.clean(_rawTranscript('x'))).okOrNull!;
      expect(ct.entities, hasLength(1));
      expect(ct.tags, <String>['x']);
    });
  });

  group('CleanupPipeline (fault tolerance)', () {
    test(
      'entity parse failure triggers retry, then falls back to empty',
      () async {
        final cleaned = _repeat(_cleanedText, 4);
        final runner = FakeLlmRunner(
          responses: <String>[
            cleaned, // cleanup
            '[]', // boundaries → fallback
            'not a json object, sorry', // entities: bad
            'still not json', // retry: also bad
            '[]', // tags
          ],
        );
        await runner.load();
        final pipeline = CleanupPipeline(runner: runner);
        final ct = (await pipeline.clean(_rawTranscript('x'))).okOrNull!;
        expect(ct.entities, isEmpty);
        // cleanup + boundaries + entities + retry + tags = 5 calls.
        expect(runner.callCount, 5);
      },
    );

    test('entity retry succeeds on second try', () async {
      final cleaned = _repeat(_cleanedText, 4);
      final runner = FakeLlmRunner(
        responses: <String>[
          cleaned,
          '[]',
          'whoops not json',
          '[{"name":"Alice","kind":"person","aliases":[],"salience":0.7}]',
          '["tag"]',
        ],
      );
      await runner.load();
      final pipeline = CleanupPipeline(runner: runner);
      final ct = (await pipeline.clean(_rawTranscript('x'))).okOrNull!;
      expect(ct.entities, hasLength(1));
      expect(ct.entities.first.name, 'Alice');
    });

    test('cleanup failure propagates as Err', () async {
      final runner = FakeLlmRunner(
        responses: const <String>['placeholder'],
        errorAfter: 0, // first call errors
      );
      await runner.load();
      final pipeline = CleanupPipeline(runner: runner);
      final result = await pipeline.clean(_rawTranscript('x'));
      expect(result.isErr, isTrue);
    });

    test('malformed tags JSON yields empty tags list', () async {
      final cleaned = _repeat(_cleanedText, 4);
      final runner = FakeLlmRunner(
        responses: <String>[
          cleaned,
          '[]',
          '[]', // entities
          'garbage tags', // tags: malformed
        ],
      );
      await runner.load();
      final pipeline = CleanupPipeline(runner: runner);
      final ct = (await pipeline.clean(_rawTranscript('x'))).okOrNull!;
      expect(ct.tags, isEmpty);
    });

    test('bad boundary JSON falls back to fixed-width chunks', () async {
      final cleaned = _repeat(_cleanedText, 4);
      final runner = FakeLlmRunner(
        responses: <String>[
          cleaned,
          'definitely not json', // boundaries: malformed
          '[]',
          '[]',
        ],
      );
      await runner.load();
      final pipeline = CleanupPipeline(runner: runner);
      final ct = (await pipeline.clean(_rawTranscript('x'))).okOrNull!;
      expect(ct.chunks, isNotEmpty);
      expect(ct.chunks.first.topicHint, '(fixed-width fallback)');
    });

    test('entity missing required name field is rejected', () async {
      final cleaned = _repeat(_cleanedText, 4);
      final runner = FakeLlmRunner(
        responses: <String>[
          cleaned,
          '[]',
          '[{"kind":"person"}]', // no name
          '[]',
          '[]',
        ],
      );
      await runner.load();
      final pipeline = CleanupPipeline(runner: runner);
      final ct = (await pipeline.clean(_rawTranscript('x'))).okOrNull!;
      expect(ct.entities, isEmpty);
    });

    test('entity out-of-range salience is clamped to [0, 1]', () async {
      final cleaned = _repeat(_cleanedText, 4);
      final runner = FakeLlmRunner(
        responses: <String>[
          cleaned,
          '[]',
          '[{"name":"X","kind":"concept","aliases":[],"salience":5.0}]',
          '[]',
        ],
      );
      await runner.load();
      final pipeline = CleanupPipeline(runner: runner);
      final ct = (await pipeline.clean(_rawTranscript('x'))).okOrNull!;
      expect(ct.entities.single.salience, 1.0);
    });
  });
}

/// Convenience matcher: assert a CleanedTranscript equals
/// [CleanedTranscript.empty] when only `text` needs checking.
class CleanedTranscriptMatch extends Matcher {
  const CleanedTranscriptMatch({required this.text});
  final String text;

  @override
  bool matches(Object? item, Map<Object?, Object?> matchState) =>
      item.toString().contains('0 chunks') && item.toString().contains('0 entities');

  @override
  Description describe(Description d) =>
      d.add('an empty CleanedTranscript with text="$text"');
}
