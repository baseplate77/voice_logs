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
            "type": "preference",
            "text": "User prefers local apps.",
            "evidence": "I prefer local apps",
            "confidence": 0.9,
            "sensitivity": "normal"
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
      expect(runner.prompts, hasLength(2));
      expect(runner.unloads, 1);
    },
  );

  test('parseMemoryCandidates keeps only validated durable memories', () {
    const cleaned =
        'I am building VoxSynth. My cardiology appointment was today.';
    final candidates = parseMemoryCandidates('''
      {
        "memories": [
          {
            "type": "project",
            "text": "User is building VoxSynth.",
            "evidence": "I am building VoxSynth",
            "confidence": 0.91,
            "sensitivity": "normal"
          },
          {
            "type": "identity",
            "text": "Low confidence item.",
            "evidence": "I am building VoxSynth",
            "confidence": 0.2,
            "sensitivity": "normal"
          },
          {
            "type": "identity",
            "text": "Invented item.",
            "evidence": "not in transcript",
            "confidence": 0.95,
            "sensitivity": "normal"
          },
          {
            "type": "event_context",
            "text": "User had a cardiology appointment today.",
            "evidence": "My cardiology appointment was today",
            "confidence": 0.8,
            "sensitivity": "sensitive"
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
    expect(candidates.last.sensitivity, MemorySensitivity.sensitive);
  });

  test('parseMemoryCandidates returns null for malformed top-level JSON', () {
    final candidates = parseMemoryCandidates(
      'not json',
      cleanedText: 'User likes local apps.',
    );

    expect(candidates, isNull);
  });
}
