import 'package:flutter_test/flutter_test.dart';
import 'package:voxsynth/core/result.dart';
import 'package:voxsynth/features/memory/memory_extractor.dart';
import 'package:voxsynth/features/memory/memory_types.dart';
import 'package:voxsynth/features/refine/llm_runner.dart';

class _FakeRunner implements LlmRunner {
  _FakeRunner(this.responses);

  final List<String> responses;
  final prompts = <String>[];
  int unloads = 0;

  @override
  Future<void> dispose() async {}

  @override
  Future<Result<String, LlmError>> generate(
    String prompt, {
    double temperature = 0.3,
    int topK = 1,
    double topP = 0.95,
    int? randomSeed,
  }) async {
    prompts.add(prompt);
    return Ok(responses.removeAt(0));
  }

  @override
  Future<Result<void, LlmError>> load() async => const Ok(null);

  @override
  Future<void> unload() async {
    unloads++;
  }
}

void main() {
  test(
    'MemoryExtractor retries malformed JSON and returns candidates',
    () async {
      final runner = _FakeRunner([
        'not json',
        '''
      {
        "memories": [
          {
            "type": "fact",
            "text": "User prefers local apps.",
            "evidence": "I prefer local apps"
          }
        ]
      }
      ''',
      ]);
      final extractor = MemoryExtractor(runner: runner);

      final res = await extractor.extract('I prefer local apps.');

      expect(res, isA<Ok<List<MemoryCandidate>, MemoryExtractionError>>());
      final candidates =
          (res as Ok<List<MemoryCandidate>, MemoryExtractionError>).value;
      expect(candidates.single.text, 'User prefers local apps.');
      expect(candidates.single.type, MemoryType.identity);
      expect(candidates.single.confidence, 0.8);
      expect(candidates.single.sensitivity, MemorySensitivity.normal);
      expect(runner.prompts, hasLength(2));
      expect(runner.unloads, 0);
    },
  );

  test('MemoryExtractor returns empty list when retry is invalid', () async {
    final runner = _FakeRunner(['not json', 'still not json']);
    final extractor = MemoryExtractor(runner: runner);

    final res = await extractor.extract('I prefer local apps.');

    expect(res, isA<Ok<List<MemoryCandidate>, MemoryExtractionError>>());
    final candidates =
        (res as Ok<List<MemoryCandidate>, MemoryExtractionError>).value;
    expect(candidates, isEmpty);
    expect(runner.prompts, hasLength(2));
    expect(runner.unloads, 0);
  });

  test('parseMemoryCandidates keeps only validated durable memories', () {
    const cleaned =
        'I am building VoxSynth. My cardiology appointment was today.';
    final candidates = parseMemoryCandidates('''
      {
        "memories": [
          {
            "type": "plan",
            "text": "User is building VoxSynth.",
            "evidence": "I am building VoxSynth"
          },
          {
            "type": "fact",
            "text": "Invented item.",
            "evidence": "not in transcript"
          },
          {
            "type": "fact",
            "text": "User had a cardiology appointment today.",
            "evidence": "My cardiology appointment was today"
          }
        ]
      }
      ''', cleanedText: cleaned);

    expect(candidates, isNotNull);
    expect(candidates, hasLength(2));
    expect(candidates!.first.type, MemoryType.project);
    expect(
      candidates.first.startChar,
      cleaned.indexOf('I am building VoxSynth'),
    );
    expect(candidates.first.confidence, 0.8);
    // "cardiology" triggers keyword-based sensitivity detection.
    expect(candidates.last.sensitivity, MemorySensitivity.sensitive);
  });

  test('parseMemoryCandidates accepts common structured-output variants', () {
    const cleaned = 'I prefer local apps.';
    final candidates = parseMemoryCandidates('''
      {
        "arguments": {
          "candidates": [
            {
              "category": "preference",
              "memory": "User prefers local apps.",
              "quote": "I prefer local apps",
              "score": "0.88"
            }
          ]
        }
      }
      ''', cleanedText: cleaned);

    expect(candidates, isNotNull);
    expect(candidates, hasLength(1));
    // "preference" still accepted — original wire types are backwards-compatible.
    expect(candidates!.single.type, MemoryType.preference);
    expect(candidates.single.sensitivity, MemorySensitivity.normal);
    // Model-provided score is honored when present.
    expect(candidates.single.confidence, 0.88);
  });

  test('parseMemoryCandidates maps simplified type aliases', () {
    const cleaned = 'I run every morning. My friend Priya helps test.';
    final candidates = parseMemoryCandidates('''
      {
        "memories": [
          {"type":"habit","text":"User runs every morning.","evidence":"I run every morning"},
          {"type":"person","text":"Priya helps test.","evidence":"My friend Priya helps test"}
        ]
      }
      ''', cleanedText: cleaned);

    expect(candidates, isNotNull);
    expect(candidates, hasLength(2));
    expect(candidates![0].type, MemoryType.routine);
    expect(candidates[1].type, MemoryType.relationship);
  });

  test('parseMemoryCandidates detects sensitivity from keywords', () {
    const cleaned = 'My therapist suggested I journal more often.';
    final candidates = parseMemoryCandidates('''
      {
        "memories": [
          {"type":"habit","text":"User journals on therapist advice.","evidence":"My therapist suggested I journal more often"}
        ]
      }
      ''', cleanedText: cleaned);

    expect(candidates, isNotNull);
    expect(candidates!.single.sensitivity, MemorySensitivity.sensitive);
  });

  test('parseMemoryCandidates returns null for malformed top-level JSON', () {
    final candidates = parseMemoryCandidates(
      'not json',
      cleanedText: 'User likes local apps.',
    );

    expect(candidates, isNull);
  });
}
