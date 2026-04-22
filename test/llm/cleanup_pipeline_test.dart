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

/// Unique substrings from each prompt template — used to dispatch
/// responses by prompt content rather than call order, since the
/// pipeline now fires cleanup/entities/tags concurrently.
const String _cleanupKey = 'VoxSynth, a transcript cleaner';
const String _boundariesKey = 'transcript segmenter';
const String _entitiesKey = 'Extract named entities';
const String _entitiesRetryKey = 'Your previous response was not valid JSON';
const String _tagsKey = 'short topic tags';

FakeLlmRunner _fake({
  required String cleanup,
  required String boundaries,
  required List<String> entities,
  required String tags,
}) {
  // Order matters inside each value list (retry uses the second entry);
  // order across keys does not.
  return FakeLlmRunner(
    keyedResponses: <String, List<String>>{
      _cleanupKey: <String>[cleanup],
      _entitiesRetryKey: entities.length > 1
          ? <String>[entities[1]]
          : const <String>[],
      _entitiesKey: <String>[entities.first],
      _boundariesKey: <String>[boundaries],
      _tagsKey: <String>[tags],
    },
  );
}

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
      final runner = _fake(
        cleanup: cleaned,
        boundaries: '[]', // empty → fixed-width fallback
        entities: const <String>[
          '[{"name":"Alice","kind":"person","aliases":[],"salience":0.8},{"name":"Bob","kind":"person","aliases":[],"salience":0.6}]',
        ],
        tags: '["pricing","q3"]',
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
      final runner = _fake(
        cleanup: cleaned,
        boundaries: '```json\n[]\n```',
        entities: const <String>[
          '```\n[{"name":"Alice","kind":"person","aliases":[],"salience":0.9}]\n```',
        ],
        tags: '```json\n["x"]\n```',
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
        final runner = _fake(
          cleanup: cleaned,
          boundaries: '[]',
          entities: const <String>[
            'not a json object, sorry', // first try: bad
            'still not json', // retry: also bad
          ],
          tags: '[]',
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
      final runner = _fake(
        cleanup: cleaned,
        boundaries: '[]',
        entities: const <String>[
          'whoops not json',
          '[{"name":"Alice","kind":"person","aliases":[],"salience":0.7}]',
        ],
        tags: '["tag"]',
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
      final runner = _fake(
        cleanup: cleaned,
        boundaries: '[]',
        entities: const <String>['[]'],
        tags: 'garbage tags',
      );
      await runner.load();
      final pipeline = CleanupPipeline(runner: runner);
      final ct = (await pipeline.clean(_rawTranscript('x'))).okOrNull!;
      expect(ct.tags, isEmpty);
    });

    test('bad boundary JSON falls back to fixed-width chunks', () async {
      final cleaned = _repeat(_cleanedText, 4);
      final runner = _fake(
        cleanup: cleaned,
        boundaries: 'definitely not json',
        entities: const <String>['[]'],
        tags: '[]',
      );
      await runner.load();
      final pipeline = CleanupPipeline(runner: runner);
      final ct = (await pipeline.clean(_rawTranscript('x'))).okOrNull!;
      expect(ct.chunks, isNotEmpty);
      expect(ct.chunks.first.topicHint, '(fixed-width fallback)');
    });

    test('entity missing required name field is rejected', () async {
      final cleaned = _repeat(_cleanedText, 4);
      final runner = _fake(
        cleanup: cleaned,
        boundaries: '[]',
        entities: const <String>[
          '[{"kind":"person"}]', // first try: missing name
          '[]', // retry: empty
        ],
        tags: '[]',
      );
      await runner.load();
      final pipeline = CleanupPipeline(runner: runner);
      final ct = (await pipeline.clean(_rawTranscript('x'))).okOrNull!;
      expect(ct.entities, isEmpty);
    });

    test('entity out-of-range salience is clamped to [0, 1]', () async {
      final cleaned = _repeat(_cleanedText, 4);
      final runner = _fake(
        cleanup: cleaned,
        boundaries: '[]',
        entities: const <String>[
          '[{"name":"X","kind":"concept","aliases":[],"salience":5.0}]',
        ],
        tags: '[]',
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
