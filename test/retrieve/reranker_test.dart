import 'package:flutter_test/flutter_test.dart';
import 'package:voxsynth/core/errors.dart';
import 'package:voxsynth/core/result.dart';
import 'package:voxsynth/llm/llm_runner.dart';
import 'package:voxsynth/retrieve/reranker.dart';
import 'package:voxsynth/store/models/voice_log_record.dart';

ChunkRecord _chunk(int id, String text) => ChunkRecord(
      id: id,
      logId: VoiceLogId('log-$id'),
      text: text,
      startChar: 0,
      endChar: text.length,
      topicHint: 'x',
      createdAt: DateTime.fromMillisecondsSinceEpoch(0),
      objectboxId: 0,
    );

List<RerankCandidate> _candidates(List<String> texts) {
  return [
    for (var i = 0; i < texts.length; i++)
      RerankCandidate(chunk: _chunk(i + 1, texts[i])),
  ];
}

/// FakeLlmRunner variant that errs exactly on the first call.
class _OneShotErrRunner extends FakeLlmRunner {
  _OneShotErrRunner(String retryResponse)
      : super(responses: <String>[retryResponse]);
  int _calls = 0;

  @override
  Future<Result<String, AppError>> generateSync(
    String prompt, {
    double? temperatureOverride,
  }) async {
    if (_calls++ == 0) {
      return const Err<String, AppError>(UnknownError('fake error'));
    }
    return super.generateSync(prompt, temperatureOverride: temperatureOverride);
  }
}

void main() {
  group('Reranker', () {
    test('empty candidates → empty scores, no LLM call', () async {
      final runner = FakeLlmRunner();
      await runner.load();
      final out = await Reranker(runner: runner).rerank(
        query: 'q',
        candidates: const <RerankCandidate>[],
      );
      expect(out, isEmpty);
      expect(runner.callCount, 0);
    });

    test('parses integer scores, normalises into [0, 1]', () async {
      final runner = FakeLlmRunner(
        responses: const <String>['{"C1": 10, "C2": 5, "C3": 0}'],
      );
      await runner.load();
      final out = await Reranker(runner: runner).rerank(
        query: 'q',
        candidates: _candidates(<String>['one', 'two', 'three']),
      );
      expect(out, hasLength(3));
      expect(out[0].chunkId, 1);
      expect(out[0].score, 1.0);
      expect(out[1].score, 0.5);
      expect(out[2].score, 0.0);
    });

    test('missing candidate scores arrive as NaN', () async {
      final runner = FakeLlmRunner(
        responses: const <String>['{"C1": 8}'],
      );
      await runner.load();
      final out = await Reranker(runner: runner).rerank(
        query: 'q',
        candidates: _candidates(<String>['one', 'two', 'three']),
      );
      expect(out[0].score, 0.8);
      expect(out[1].score.isNaN, isTrue);
      expect(out[2].score.isNaN, isTrue);
    });

    test('floats outside [0, 10] are clamped', () async {
      final runner = FakeLlmRunner(
        responses: const <String>['{"C1": 15, "C2": -3, "C3": 7.5}'],
      );
      await runner.load();
      final out = await Reranker(runner: runner).rerank(
        query: 'q',
        candidates: _candidates(<String>['a', 'b', 'c']),
      );
      expect(out[0].score, 1.0);
      expect(out[1].score, 0.0);
      expect(out[2].score, 0.75);
    });

    test('retries once on malformed JSON', () async {
      final runner = FakeLlmRunner(
        responses: const <String>[
          'I refuse',
          '{"C1": 9, "C2": 3}',
        ],
      );
      await runner.load();
      final out = await Reranker(runner: runner).rerank(
        query: 'q',
        candidates: _candidates(<String>['a', 'b']),
      );
      expect(out[0].score, 0.9);
      expect(out[1].score, 0.3);
      expect(runner.callCount, 2);
    });

    test('retries on LLM error', () async {
      final runner = _OneShotErrRunner('{"C1": 5}');
      await runner.load();
      final out = await Reranker(runner: runner).rerank(
        query: 'q',
        candidates: _candidates(<String>['a']),
      );
      expect(out.single.score, 0.5);
    });

    test('double failure → all-NaN output (same length as input)',
        () async {
      final runner = FakeLlmRunner(
        responses: const <String>['not json', 'still not json'],
      );
      await runner.load();
      final out = await Reranker(runner: runner).rerank(
        query: 'q',
        candidates: _candidates(<String>['a', 'b', 'c']),
      );
      expect(out, hasLength(3));
      for (final s in out) {
        expect(s.score.isNaN, isTrue);
      }
    });

    test('caps at kRerankMaxCandidates (20)', () async {
      final runner = FakeLlmRunner(
        responses: const <String>['{"C1": 5}'],
      );
      await runner.load();
      final many = _candidates(
        List<String>.generate(30, (i) => 'chunk $i'),
      );
      final out =
          await Reranker(runner: runner).rerank(query: 'q', candidates: many);
      expect(out, hasLength(kRerankMaxCandidates));
    });

    test('strips markdown code fences around JSON', () async {
      final runner = FakeLlmRunner(
        responses: const <String>[
          '```json\n{"C1": 7}\n```',
        ],
      );
      await runner.load();
      final out = await Reranker(runner: runner).rerank(
        query: 'q',
        candidates: _candidates(<String>['one']),
      );
      expect(out.single.score, 0.7);
    });

    test('non-C<n> keys are ignored', () async {
      final runner = FakeLlmRunner(
        responses: const <String>['{"something": 5, "C1": 9}'],
      );
      await runner.load();
      final out = await Reranker(runner: runner).rerank(
        query: 'q',
        candidates: _candidates(<String>['x']),
      );
      expect(out.single.score, 0.9);
    });
  });
}
