import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voxsynth/core/db/database.dart';
import 'package:voxsynth/core/db/job_state.dart';
import 'package:voxsynth/core/db/repositories/entity_mention_repository.dart';
import 'package:voxsynth/core/db/repositories/prompt_suggestion_repository.dart';
import 'package:voxsynth/core/db/repositories/voice_log_repository.dart';
import 'package:voxsynth/core/result.dart';
import 'package:voxsynth/core/worker/job_handler.dart';
import 'package:voxsynth/core/worker/job_queue.dart';
import 'package:voxsynth/features/refine/llm_runner.dart';
import 'package:voxsynth/features/refine/refine_runner.dart';
import 'package:voxsynth/features/refine/transcript_chunker.dart';

class _ScriptedRunner implements LlmRunner {
  _ScriptedRunner(this.responses);
  final List<String> responses;
  final prompts = <String>[];
  final temperatures = <double>[];
  final topKs = <int>[];

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
    temperatures.add(temperature);
    topKs.add(topK);
    if (responses.isEmpty) {
      return const Err(LlmRuntimeError(message: 'no scripted response'));
    }
    return Ok(responses.removeAt(0));
  }

  @override
  Future<Result<void, LlmError>> load() async => const Ok(null);

  @override
  Future<void> unload() async {}
}

const _validCleanupJson = '{"cleaned_text":"Shivani is my coworker."}';
const _validTitleJson = '{"title":"Shivani coworker note"}';
const _validEntitiesJson = '''
{
  "entities": [
    {"text": "Shivani", "type": "PERSON"}
  ]
}
''';

Future<
  ({
    VoxSynthDatabase db,
    JobQueue queue,
    VoiceLogRepository logs,
    EntityMentionRepository mentions,
  })
>
_setup({String rawTranscript = 'shivani is my coworker'}) async {
  final db = VoxSynthDatabase(NativeDatabase.memory());
  final logs = VoiceLogRepository(db);
  final mentions = EntityMentionRepository(db);
  final queue = JobQueue(db);
  await logs.insertRecorded(
    id: 'log_1',
    createdAt: DateTime(2026, 5, 9),
    durationMs: 1000,
    audioPath: 'audio/log_1.wav',
    rawTranscript: rawTranscript,
  );
  return (db: db, queue: queue, logs: logs, mentions: mentions);
}

void main() {
  test('LlmRefiner refines, persists mentions, and enqueues embed', () async {
    final ctx = await _setup();
    addTearDown(ctx.db.close);

    final runner = _ScriptedRunner([
      _validCleanupJson,
      _validTitleJson,
      _validEntitiesJson,
    ]);
    final refiner = LlmRefiner(
      runner: runner,
      voiceLogs: ctx.logs,
      mentions: ctx.mentions,
      queue: ctx.queue,
    );

    final outcome = await refiner.handle(
      const JobContext(jobId: 'job_1', logId: 'log_1', attempts: 0),
    );
    expect(outcome.isOk, isTrue);
    final value = (outcome as Ok).value;
    expect(value, isA<JobSucceeded>());

    final stored = await ctx.logs.find('log_1');
    expect(stored?.cleanedText, 'Shivani is my coworker.');
    expect(stored?.title, 'Shivani coworker note');

    final storedMentions = await ctx.mentions.forLog('log_1');
    expect(storedMentions, hasLength(1));
    expect(storedMentions.first.text, 'Shivani');

    expect(runner.prompts, hasLength(3));
    expect(runner.prompts[0], contains('Clean this transcript only'));
    expect(runner.prompts[1], contains("VoxSynth's local log titler"));
    expect(runner.prompts[2], contains('Extract entities'));
    expect(runner.temperatures, [0, 0, 0]);
    // Refine deliberately stays on greedy decoding (topK=1) so its JSON
    // output remains deterministic and parses cleanly every time. This is
    // the opposite of what Ask wants — see ask_assistant_test for that.
    expect(runner.topKs, [1, 1, 1]);
    final next = await ctx.queue.claimNext();
    expect(next?.jobType, JobType.embed);
    expect(next?.logId, 'log_1');
  });

  test('LlmRefiner retries on parse failure then succeeds', () async {
    final ctx = await _setup();
    addTearDown(ctx.db.close);

    final runner = _ScriptedRunner([
      'not json at all',
      _validCleanupJson,
      _validTitleJson,
      _validEntitiesJson,
    ]);
    final refiner = LlmRefiner(
      runner: runner,
      voiceLogs: ctx.logs,
      mentions: ctx.mentions,
      queue: ctx.queue,
    );

    final outcome = await refiner.handle(
      const JobContext(jobId: 'job_1', logId: 'log_1', attempts: 0),
    );
    expect(outcome.isOk, isTrue);
    expect(runner.prompts, hasLength(4));
    expect(runner.temperatures, [0, 0, 0, 0]);
    final stored = await ctx.logs.find('log_1');
    expect(stored?.cleanedText, 'Shivani is my coworker.');
    expect(stored?.title, 'Shivani coworker note');
  });

  test('LlmRefiner retries when cleanup drops transcript content', () async {
    final raw = List<String>.generate(
      12,
      (i) => 'project atlas detail $i happened with shivani at office',
    ).join(' ');
    final preserved = '${raw.replaceAll('shivani', 'Shivani')}.';
    final ctx = await _setup(rawTranscript: raw);
    addTearDown(ctx.db.close);

    final runner = _ScriptedRunner([
      '{"cleaned_text":"Project Atlas had a few updates."}',
      '{"cleaned_text":"$preserved"}',
      _validTitleJson,
      '{"entities":[]}',
    ]);
    final refiner = LlmRefiner(
      runner: runner,
      voiceLogs: ctx.logs,
      mentions: ctx.mentions,
      queue: ctx.queue,
    );

    final outcome = await refiner.handle(
      const JobContext(jobId: 'job_1', logId: 'log_1', attempts: 0),
    );

    expect(outcome.isOk, isTrue);
    expect(runner.prompts, hasLength(4));
    expect(runner.prompts[1], contains('lost information'));
    final stored = await ctx.logs.find('log_1');
    expect(stored?.cleanedText, preserved);
  });

  test(
    'LlmRefiner falls back to raw transcript when cleanup drops content twice',
    () async {
      final raw = List<String>.generate(
        12,
        (i) => 'project atlas detail $i happened with shivani at office',
      ).join(' ');
      final ctx = await _setup(rawTranscript: raw);
      addTearDown(ctx.db.close);

      final runner = _ScriptedRunner([
        '{"cleaned_text":"Project Atlas had updates."}',
        '{"cleaned_text":"Still only a short summary."}',
      ]);
      final refiner = LlmRefiner(
        runner: runner,
        voiceLogs: ctx.logs,
        mentions: ctx.mentions,
        queue: ctx.queue,
      );

      final outcome = await refiner.handle(
        const JobContext(jobId: 'job_1', logId: 'log_1', attempts: 0),
      );

      expect(outcome.isOk, isTrue);
      final stored = await ctx.logs.find('log_1');
      expect(stored?.cleanedText, raw);
      final storedMentions = await ctx.mentions.forLog('log_1');
      expect(storedMentions, isEmpty);
    },
  );

  test('LlmRefiner refines long transcripts chunk by chunk', () async {
    final raw = List<String>.generate(
      45,
      (i) =>
          'project atlas update $i with shivani at office. follow up with notes for milestone $i.',
    ).join(' ');
    final rawChunks = splitTranscriptForRefine(raw);
    expect(rawChunks.length, greaterThan(1));

    final cleanedChunks = rawChunks
        .map((c) => c.text.replaceAll('shivani', 'Shivani').trim())
        .toList();
    final expectedCleaned = cleanedChunks.join(' ');
    final entityChunks = splitTranscriptForRefine(expectedCleaned);

    final responses = <String>[
      for (final chunk in cleanedChunks)
        jsonEncode(<String, String>{'cleaned_text': chunk}),
      _validTitleJson,
      for (var i = 0; i < entityChunks.length; i++) '{"entities":[]}',
    ];

    final ctx = await _setup(rawTranscript: raw);
    addTearDown(ctx.db.close);

    final runner = _ScriptedRunner(responses);
    final refiner = LlmRefiner(
      runner: runner,
      voiceLogs: ctx.logs,
      mentions: ctx.mentions,
      queue: ctx.queue,
    );

    final outcome = await refiner.handle(
      const JobContext(jobId: 'job_1', logId: 'log_1', attempts: 0),
    );

    expect(outcome.isOk, isTrue);
    final stored = await ctx.logs.find('log_1');
    expect(stored?.cleanedText, expectedCleaned);
    expect(
      runner.prompts.where((p) => p.contains('Clean this transcript only')),
      hasLength(rawChunks.length),
    );
    expect(
      runner.prompts.where((p) => p.contains('Extract entities')),
      hasLength(entityChunks.length),
    );
  });

  test(
    'LlmRefiner falls back to raw transcript when retry also fails',
    () async {
      final ctx = await _setup();
      addTearDown(ctx.db.close);

      final runner = _ScriptedRunner(['nope', 'still nope']);
      final refiner = LlmRefiner(
        runner: runner,
        voiceLogs: ctx.logs,
        mentions: ctx.mentions,
        queue: ctx.queue,
      );

      final outcome = await refiner.handle(
        const JobContext(jobId: 'job_1', logId: 'log_1', attempts: 0),
      );
      expect(outcome.isOk, isTrue);
      final stored = await ctx.logs.find('log_1');
      expect(stored?.cleanedText, 'shivani is my coworker');
      final storedMentions = await ctx.mentions.forLog('log_1');
      expect(storedMentions, isEmpty);
    },
  );

  test(
    'dedicated title stage overrides anything embedded in legacy cleanup',
    () async {
      final ctx = await _setup();
      addTearDown(ctx.db.close);

      // Even when cleanup carries a legacy title key, the dedicated stage
      // wins because it has seen the full transcript.
      final runner = _ScriptedRunner([
        '{"cleaned_text":"Shivani is my coworker.","title":"old title"}',
        '{"title":"Shivani coworker note"}',
        _validEntitiesJson,
      ]);
      final refiner = LlmRefiner(
        runner: runner,
        voiceLogs: ctx.logs,
        mentions: ctx.mentions,
        queue: ctx.queue,
      );

      final outcome = await refiner.handle(
        const JobContext(jobId: 'job_1', logId: 'log_1', attempts: 0),
      );
      expect(outcome.isOk, isTrue);
      final stored = await ctx.logs.find('log_1');
      expect(stored?.title, 'Shivani coworker note');
    },
  );

  test(
    'title stage Err falls back to legacy cleanup title when present',
    () async {
      final ctx = await _setup();
      addTearDown(ctx.db.close);

      // Cleanup carries a legacy title; title stage Gemma call returns Err
      // (no scripted response after we exhaust the list); refiner should
      // fall through to the legacy title without crashing.
      final runner = _ScriptedRunner([
        '{"cleaned_text":"Shivani is my coworker.","title":"legacy fallback"}',
        // Title Gemma call: scripted response is malformed garbage so both
        // initial parse and retry fail.
        'not json',
        'still not json',
        _validEntitiesJson,
      ]);
      final refiner = LlmRefiner(
        runner: runner,
        voiceLogs: ctx.logs,
        mentions: ctx.mentions,
        queue: ctx.queue,
      );

      final outcome = await refiner.handle(
        const JobContext(jobId: 'job_1', logId: 'log_1', attempts: 0),
      );
      expect(outcome.isOk, isTrue);
      final stored = await ctx.logs.find('log_1');
      expect(stored?.title, 'legacy fallback');
    },
  );

  test(
    'title stage Err and no legacy title falls back to synthesized title',
    () async {
      final ctx = await _setup();
      addTearDown(ctx.db.close);

      // Provide cleanup + entity responses, but NO title response. Both the
      // initial title call and the stricter retry get an Err from the
      // scripted runner, so _resolveTitle must fall back to the synthesized
      // deterministic title before the entity stage even runs.
      final runner = _StubbedTitleRunner(
        cleanupResponses: [_validCleanupJson],
        entityResponses: [_validEntitiesJson],
      );
      final refiner = LlmRefiner(
        runner: runner,
        voiceLogs: ctx.logs,
        mentions: ctx.mentions,
        queue: ctx.queue,
      );

      final outcome = await refiner.handle(
        const JobContext(jobId: 'job_1', logId: 'log_1', attempts: 0),
      );
      expect(outcome.isOk, isTrue);
      final stored = await ctx.logs.find('log_1');
      // Deterministic fallback: first non-stop words from the cleaned text.
      expect(stored?.title, isNotNull);
      expect(stored!.title!.toLowerCase(), contains('shivani'));
    },
  );

  test('title stage retries once on parse failure before succeeding', () async {
    final ctx = await _setup();
    addTearDown(ctx.db.close);

    final runner = _ScriptedRunner([
      _validCleanupJson,
      'no valid json here', // initial title -> no JSON -> parse fails -> retry
      '{"title":"After retry success"}',
      _validEntitiesJson,
    ]);
    final refiner = LlmRefiner(
      runner: runner,
      voiceLogs: ctx.logs,
      mentions: ctx.mentions,
      queue: ctx.queue,
    );

    final outcome = await refiner.handle(
      const JobContext(jobId: 'job_1', logId: 'log_1', attempts: 0),
    );
    expect(outcome.isOk, isTrue);
    final stored = await ctx.logs.find('log_1');
    expect(stored?.title, 'After retry success');
    expect(runner.prompts, hasLength(4));
  });

  test('suggestion stage persists chips when provided a repository', () async {
    final ctx = await _setup();
    addTearDown(ctx.db.close);
    final suggestions = PromptSuggestionRepository(ctx.db);

    const suggestionsJson =
        '{"suggestions":['
        '{"chip":"Coffee with Shivani","question":"What did I discuss with Shivani?"},'
        '{"chip":"Project Atlas","question":"What is the latest on Atlas?"}'
        ']}';
    final runner = _ScriptedRunner([
      _validCleanupJson,
      _validTitleJson,
      _validEntitiesJson,
      suggestionsJson,
    ]);
    final refiner = LlmRefiner(
      runner: runner,
      voiceLogs: ctx.logs,
      mentions: ctx.mentions,
      queue: ctx.queue,
      suggestions: suggestions,
    );

    final outcome = await refiner.handle(
      const JobContext(jobId: 'job_1', logId: 'log_1', attempts: 0),
    );
    expect(outcome.isOk, isTrue);

    final stored = await suggestions.all();
    expect(stored, hasLength(2));
    expect(
      stored.map((s) => s.chipText),
      containsAll(['Coffee with Shivani', 'Project Atlas']),
    );
  });

  test(
    'suggestion stage failure does not break refine — log still finishes',
    () async {
      final ctx = await _setup();
      addTearDown(ctx.db.close);
      final suggestions = PromptSuggestionRepository(ctx.db);

      final runner = _ScriptedRunner([
        _validCleanupJson,
        _validTitleJson,
        _validEntitiesJson,
        // No scripted suggestion response — both initial + retry calls Err.
      ]);
      final refiner = LlmRefiner(
        runner: runner,
        voiceLogs: ctx.logs,
        mentions: ctx.mentions,
        queue: ctx.queue,
        suggestions: suggestions,
      );

      final outcome = await refiner.handle(
        const JobContext(jobId: 'job_1', logId: 'log_1', attempts: 0),
      );
      expect(outcome.isOk, isTrue);
      final storedLog = await ctx.logs.find('log_1');
      expect(storedLog?.cleanedText, 'Shivani is my coworker.');
      final storedChips = await suggestions.all();
      expect(storedChips, isEmpty);
      // Embed job is still queued — refine reported success.
      final next = await ctx.queue.claimNext();
      expect(next?.jobType, JobType.embed);
    },
  );

  test('bumpUsage increments used_count and stamps last_used_at', () async {
    final ctx = await _setup();
    addTearDown(ctx.db.close);
    final suggestions = PromptSuggestionRepository(ctx.db);

    await suggestions.replaceForLog(
      logId: 'log_1',
      candidates: const [
        PromptSuggestionCandidate(
          chipText: 'Coffee with Shivani',
          question: 'What did I discuss with Shivani?',
        ),
      ],
    );
    final before = (await suggestions.all()).single;
    expect(before.usedCount, 0);
    expect(before.lastUsedAt, isNull);

    await suggestions.bumpUsage(before.id);
    final after = (await suggestions.all()).single;
    expect(after.usedCount, 1);
    expect(after.lastUsedAt, isNotNull);
  });
}

/// Routes by prompt content so a test can withhold title responses without
/// also starving cleanup/entity stages.
class _StubbedTitleRunner implements LlmRunner {
  _StubbedTitleRunner({
    required this.cleanupResponses,
    required this.entityResponses,
  });

  final List<String> cleanupResponses;
  final List<String> entityResponses;
  final prompts = <String>[];

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
    if (prompt.contains('local log titler') ||
        prompt.contains('"title":"4-10 word')) {
      return const Err(LlmRuntimeError(message: 'title stage offline'));
    }
    if (prompt.contains('Extract entities') ||
        prompt.contains('exact substring')) {
      if (entityResponses.isEmpty) {
        return const Err(LlmRuntimeError(message: 'no entity response'));
      }
      return Ok(entityResponses.removeAt(0));
    }
    if (cleanupResponses.isEmpty) {
      return const Err(LlmRuntimeError(message: 'no cleanup response'));
    }
    return Ok(cleanupResponses.removeAt(0));
  }

  @override
  Future<Result<void, LlmError>> load() async => const Ok(null);

  @override
  Future<void> unload() async {}
}
