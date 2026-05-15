import 'package:flutter_test/flutter_test.dart';
import 'package:voxsynth/core/result.dart';
import 'package:voxsynth/features/ask/ask_assistant.dart';
import 'package:voxsynth/features/memory/memory_retriever.dart';
import 'package:voxsynth/features/memory/memory_types.dart';
import 'package:voxsynth/features/refine/llm_runner.dart';
import 'package:voxsynth/features/search/hybrid_retriever.dart';

class _FakeLlmRunner implements LlmRunner {
  _FakeLlmRunner(this.response);

  final Result<String, LlmError> response;
  String? prompt;
  var generateCalls = 0;
  double? capturedTemperature;
  int? capturedTopK;
  double? capturedTopP;

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
    this.prompt = prompt;
    generateCalls += 1;
    capturedTemperature = temperature;
    capturedTopK = topK;
    capturedTopP = topP;
    return response;
  }

  @override
  Future<Result<void, LlmError>> load() async => const Ok(null);

  @override
  Future<void> unload() async {}
}

class _StreamingFakeLlmRunner extends _FakeLlmRunner
    implements StreamingLlmRunner {
  _StreamingFakeLlmRunner(this.chunks) : super(Ok(chunks.join()));

  final List<String> chunks;
  var streamCalls = 0;

  @override
  Stream<Result<String, LlmError>> generateStream(
    String prompt, {
    double temperature = 0.3,
    int topK = 1,
    double topP = 0.95,
    int? randomSeed,
  }) async* {
    this.prompt = prompt;
    streamCalls += 1;
    capturedTemperature = temperature;
    capturedTopK = topK;
    capturedTopP = topP;
    for (final chunk in chunks) {
      yield Ok(chunk);
    }
  }
}

void main() {
  test(
    'retrieves memory and log context before generating an answer',
    () async {
      final runner = _FakeLlmRunner(
        const Ok('Use the local-first notes. [M1]'),
      );
      final assistant = AskAssistant(
        runner: runner,
        searchMemories: (_, {int limit = 3}) async => Ok([_memoryHit()]),
        searchLogs: (_, {int limit = 3}) async => Ok([
          SearchHit(
            logId: 'log_1',
            fusedScore: 0.3,
            matchedVia: {MatchSource.fts},
            snippet: 'I liked the local-first prototype discussion.',
            createdAt: DateTime(2026, 5, 8),
          ),
        ]),
      );

      final result = await assistant.ask('What app style do I prefer?');

      expect(result, isA<Ok<AskAnswer, AskError>>());
      final answer = (result as Ok<AskAnswer, AskError>).value;
      expect(answer.answer, 'Use the local-first notes. [M1]');
      expect(answer.memoryHits, hasLength(1));
      expect(answer.logHits, hasLength(1));
      expect(runner.generateCalls, 1);
      expect(runner.prompt, contains('Question: What app style do I prefer?'));
      expect(runner.prompt, contains('[M1] preference'));
      expect(runner.prompt, contains('[L1]'));
      expect(runner.prompt, contains('I liked'));
    },
  );

  test(
    'askStream emits context, deltas, and final structured answer',
    () async {
      final runner = _StreamingFakeLlmRunner([
        '## Answer\n',
        'Use the local notes. [M1]\n\n',
        '## Evidence\n- [M1] preference confirms it.',
      ]);
      final assistant = AskAssistant(
        runner: runner,
        searchMemories: (_, {int limit = 3}) async => Ok([_memoryHit()]),
        searchLogs: (_, {int limit = 3}) async => const Ok([]),
      );

      final events = await assistant.askStream('privacy').toList();

      expect(events, hasLength(5));
      expect(
        (events[0] as Ok<AskStreamEvent, AskError>).value,
        isA<AskContextReady>(),
      );
      expect(
        (events[1] as Ok<AskStreamEvent, AskError>).value,
        isA<AskAnswerDelta>(),
      );
      final done = (events.last as Ok<AskStreamEvent, AskError>).value;
      expect(done, isA<AskAnswerDone>());
      expect((done as AskAnswerDone).answer.answer, contains('## Answer'));
      expect(runner.streamCalls, 1);
      expect(runner.generateCalls, 0);
    },
  );

  test('skips LLM generation when retrieval finds no context', () async {
    final runner = _FakeLlmRunner(const Ok('should not be used'));
    final assistant = AskAssistant(
      runner: runner,
      searchMemories: (_, {int limit = 3}) async => const Ok([]),
      searchLogs: (_, {int limit = 3}) async => const Ok([]),
    );

    final result = await assistant.ask('unknown thing');

    expect(result, isA<Ok<AskAnswer, AskError>>());
    final answer = (result as Ok<AskAnswer, AskError>).value;
    expect(
      answer.answer,
      contains("don't have enough context from your voice logs"),
    );
    expect(runner.generateCalls, 0);
  });

  test('returns validation error for empty questions', () async {
    final runner = _FakeLlmRunner(const Ok('unused'));
    final assistant = AskAssistant(
      runner: runner,
      searchMemories: (_, {int limit = 3}) async => const Ok([]),
      searchLogs: (_, {int limit = 3}) async => const Ok([]),
    );

    final result = await assistant.ask('   ');

    expect(result, isA<Err<AskAnswer, AskError>>());
    expect(
      (result as Err<AskAnswer, AskError>).error,
      isA<AskValidationError>(),
    );
    expect(runner.generateCalls, 0);
  });

  test('degrades gracefully when memory retrieval fails', () async {
    final runner = _FakeLlmRunner(
      const Ok('## Answer\nBased on your log. [L1]\n\n## Evidence\n- [L1]'),
    );
    final assistant = AskAssistant(
      runner: runner,
      searchMemories: (_, {int limit = 3}) async =>
          const Err(MemoryRetrieverDbError(message: 'db unavailable')),
      searchLogs: (_, {int limit = 3}) async => Ok([
        SearchHit(
          logId: 'log_1',
          fusedScore: 0.3,
          matchedVia: {MatchSource.fts},
          snippet: 'relevant voice log content',
          createdAt: DateTime(2026, 5, 8),
        ),
      ]),
    );

    final result = await assistant.ask('privacy');

    expect(result, isA<Ok<AskAnswer, AskError>>());
    final answer = (result as Ok<AskAnswer, AskError>).value;
    expect(answer.memoryHits, isEmpty);
    expect(answer.logHits, hasLength(1));
    expect(runner.generateCalls, 1);
  });

  test('returns error only when both retrievers fail', () async {
    final runner = _FakeLlmRunner(const Ok('unused'));
    final assistant = AskAssistant(
      runner: runner,
      searchMemories: (_, {int limit = 3}) async =>
          const Err(MemoryRetrieverDbError(message: 'db unavailable')),
      searchLogs: (_, {int limit = 3}) async =>
          const Err(RetrieverDbError(message: 'also unavailable')),
    );

    final result = await assistant.ask('privacy');

    expect(result, isA<Err<AskAnswer, AskError>>());
    expect(
      (result as Err<AskAnswer, AskError>).error,
      isA<AskRetrievalError>(),
    );
    expect(runner.generateCalls, 0);
  });

  test('wraps LLM failures', () async {
    final runner = _FakeLlmRunner(
      const Err(LlmRuntimeError(message: 'model unavailable')),
    );
    final assistant = AskAssistant(
      runner: runner,
      searchMemories: (_, {int limit = 3}) async => Ok([_memoryHit()]),
      searchLogs: (_, {int limit = 3}) async => const Ok([]),
    );

    final result = await assistant.ask('privacy');

    expect(result, isA<Err<AskAnswer, AskError>>());
    expect((result as Err<AskAnswer, AskError>).error, isA<AskLlmError>());
    expect(runner.generateCalls, 1);
  });

  test(
    'Ask passes Gemma-recommended sampling (not greedy decoding) to the LLM',
    () async {
      // Regression guard: flutter_gemma defaults topK to 1, which forces
      // greedy decoding and reliably loops on Gemma 3 1B. Ask must override
      // with Google's recommended config — temperature=1.0, topK=64, topP=0.95.
      // The numbers come from the Gemma 3 technical report and HF model card.
      final runner = _FakeLlmRunner(const Ok('Hello [L1].'));
      final assistant = AskAssistant(
        runner: runner,
        searchMemories: (_, {int limit = 3}) async => const Ok([]),
        searchLogs: (_, {int limit = 3}) async => Ok([
          SearchHit(
            logId: 'log_1',
            fusedScore: 0.5,
            matchedVia: const {MatchSource.fts},
            snippet: 'hello',
            createdAt: DateTime(2026, 5, 8),
          ),
        ]),
      );

      await assistant.ask('hello?');
      expect(
        runner.capturedTemperature,
        1.0,
        reason: 'temperature must be 1.0 — Gemma 3 official recommendation',
      );
      expect(
        runner.capturedTopK,
        64,
        reason:
            'topK must be 64 — the value that actually defeats loops; '
            'topK=1 (flutter_gemma default) was the root cause of the bug',
      );
    },
  );

  test('streaming Ask also passes the non-greedy sampling config', () async {
    final runner = _StreamingFakeLlmRunner(['Hello ', '[L1].']);
    final assistant = AskAssistant(
      runner: runner,
      searchMemories: (_, {int limit = 3}) async => const Ok([]),
      searchLogs: (_, {int limit = 3}) async => Ok([
        SearchHit(
          logId: 'log_1',
          fusedScore: 0.5,
          matchedVia: const {MatchSource.fts},
          snippet: 'hello',
          createdAt: DateTime(2026, 5, 8),
        ),
      ]),
    );

    await assistant.ask('hello?');
    expect(runner.capturedTemperature, 1.0);
    expect(runner.capturedTopK, 64);
  });

  test('strips invalid citations from the answer', () async {
    final runner = _FakeLlmRunner(
      const Ok('Answer with [M1] and [M4] and [L1] and [L5].'),
    );
    final assistant = AskAssistant(
      runner: runner,
      searchMemories: (_, {int limit = 3}) async => Ok([_memoryHit()]),
      searchLogs: (_, {int limit = 3}) async => Ok([
        SearchHit(
          logId: 'log_1',
          fusedScore: 0.3,
          matchedVia: {MatchSource.fts},
          snippet: 'some log',
          createdAt: DateTime(2026, 5, 8),
        ),
      ]),
    );

    final result = await assistant.ask('test');

    expect(result, isA<Ok<AskAnswer, AskError>>());
    final answer = (result as Ok<AskAnswer, AskError>).value;
    expect(answer.answer, contains('[M1]'));
    expect(answer.answer, contains('[L1]'));
    expect(answer.answer, isNot(contains('[M4]')));
    expect(answer.answer, isNot(contains('[L5]')));
  });
}

MemoryHit _memoryHit() {
  return MemoryHit(
    memory: MemoryItemView(
      id: 'mem_1',
      type: MemoryType.preference,
      text: 'User prefers local-first privacy-preserving apps.',
      normalizedText: 'user prefers local first privacy preserving apps',
      confidence: 0.95,
      status: MemoryStatus.active,
      sensitivity: MemorySensitivity.normal,
      firstSeenAt: DateTime(2026, 5),
      lastSeenAt: DateTime(2026, 5),
      createdAt: DateTime(2026, 5),
      updatedAt: DateTime(2026, 5),
      embedding: null,
    ),
    fusedScore: 0.5,
    matchedVia: const {MemoryMatchSource.fts},
  );
}
