import 'package:flutter_test/flutter_test.dart';
import 'package:voxsynth/core/errors.dart';
import 'package:voxsynth/core/result.dart';
import 'package:voxsynth/llm/llm_runner.dart';
import 'package:voxsynth/retrieve/query_expander.dart';

/// Fake that errors on its first call and returns a scripted response
/// on the second. Covers the "runner failure triggers retry" path
/// that the default `errorAfter` fake can't (because `errorAfter`
/// makes *every* later call err too).
class _FirstCallErrRunner extends FakeLlmRunner {
  _FirstCallErrRunner(String retryResponse)
      : super(responses: <String>[retryResponse]);

  int _calls = 0;

  @override
  Future<Result<String, AppError>> generateSync(
    String prompt, {
    double? temperatureOverride,
  }) async {
    if (_calls++ == 0) {
      return const Err<String, AppError>(
        UnknownError('scripted first-call failure'),
      );
    }
    return super.generateSync(prompt, temperatureOverride: temperatureOverride);
  }
}

void main() {
  group('QueryExpander', () {
    test('empty query short-circuits', () async {
      final runner = FakeLlmRunner();
      await runner.load();
      final ex = await QueryExpander(runner: runner).expand('');
      expect(ex.original, '');
      expect(ex.paraphrases, isEmpty);
      expect(ex.entities, isEmpty);
      // Runner untouched.
      expect(runner.callCount, 0);
    });

    test('parses paraphrases + entities from well-formed JSON',
        () async {
      final runner = FakeLlmRunner(
        responses: const <String>[
          '{"paraphrases":["how was pricing decided","what pricing tiers"],"entities":["GlowUp"]}',
        ],
      );
      await runner.load();
      final ex = await QueryExpander(runner: runner)
          .expand('What did we decide about GlowUp pricing?');
      expect(ex.original, 'What did we decide about GlowUp pricing?');
      expect(ex.paraphrases, hasLength(2));
      expect(ex.entities, <String>['GlowUp']);
    });

    test('caps paraphrases at 2 even if the LLM returns more',
        () async {
      final runner = FakeLlmRunner(
        responses: const <String>[
          '{"paraphrases":["a","b","c","d"],"entities":[]}',
        ],
      );
      await runner.load();
      final ex = await QueryExpander(runner: runner).expand('x');
      expect(ex.paraphrases, hasLength(2));
      expect(ex.paraphrases, <String>['a', 'b']);
    });

    test('retries once with stricter prompt on bad JSON', () async {
      final runner = FakeLlmRunner(
        responses: const <String>[
          'I cannot help with that request',
          '{"paraphrases":["retried version"],"entities":[]}',
        ],
      );
      await runner.load();
      final ex = await QueryExpander(runner: runner).expand('q');
      expect(ex.paraphrases, <String>['retried version']);
      expect(runner.callCount, 2);
    });

    test('falls back to original query when both attempts fail',
        () async {
      final runner = FakeLlmRunner(
        responses: const <String>['garbage', 'still garbage'],
      );
      await runner.load();
      final ex = await QueryExpander(runner: runner).expand('fallback test');
      expect(ex.original, 'fallback test');
      expect(ex.paraphrases, isEmpty);
      expect(ex.entities, isEmpty);
    });

    test('strips markdown code fences around JSON', () async {
      final runner = FakeLlmRunner(
        responses: const <String>[
          '```json\n{"paraphrases":["hello"],"entities":[]}\n```',
        ],
      );
      await runner.load();
      final ex = await QueryExpander(runner: runner).expand('hi');
      expect(ex.paraphrases, <String>['hello']);
    });

    test('empty/whitespace paraphrases are filtered out', () async {
      final runner = FakeLlmRunner(
        responses: const <String>[
          '{"paraphrases":["","   ","good one"],"entities":[]}',
        ],
      );
      await runner.load();
      final ex = await QueryExpander(runner: runner).expand('q');
      expect(ex.paraphrases, <String>['good one']);
    });

    test('allQueries puts original first', () async {
      final runner = FakeLlmRunner(
        responses: const <String>[
          '{"paraphrases":["p1","p2"],"entities":[]}',
        ],
      );
      await runner.load();
      final ex = await QueryExpander(runner: runner).expand('orig');
      expect(ex.allQueries, <String>['orig', 'p1', 'p2']);
    });

    test('missing entities field is tolerated', () async {
      final runner = FakeLlmRunner(
        responses: const <String>[
          '{"paraphrases":["hi"]}',
        ],
      );
      await runner.load();
      final ex = await QueryExpander(runner: runner).expand('q');
      expect(ex.entities, isEmpty);
      expect(ex.paraphrases, <String>['hi']);
    });

    test('LLM runner failure triggers the retry path', () async {
      final runner = _FirstCallErrRunner(
        '{"paraphrases":["retried"],"entities":[]}',
      );
      await runner.load();
      final ex = await QueryExpander(runner: runner).expand('q');
      expect(ex.paraphrases, <String>['retried']);
    });
  });
}
