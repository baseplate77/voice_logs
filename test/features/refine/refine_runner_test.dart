import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voxsynth/core/db/database.dart';
import 'package:voxsynth/core/db/job_state.dart';
import 'package:voxsynth/core/db/repositories/entity_mention_repository.dart';
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

  @override
  Future<void> dispose() async {}

  @override
  Future<Result<String, LlmError>> generate(
    String prompt, {
    double temperature = 0.3,
  }) async {
    prompts.add(prompt);
    temperatures.add(temperature);
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

    final runner = _ScriptedRunner([_validCleanupJson, _validEntitiesJson]);
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

    final storedMentions = await ctx.mentions.forLog('log_1');
    expect(storedMentions, hasLength(1));
    expect(storedMentions.first.text, 'Shivani');

    expect(runner.prompts, hasLength(2));
    expect(runner.prompts.first, contains('Clean this transcript only'));
    expect(runner.prompts.last, contains('Extract entities'));
    expect(runner.temperatures, [0, 0]);
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
    expect(runner.prompts, hasLength(3));
    expect(runner.temperatures, [0, 0, 0]);
    final stored = await ctx.logs.find('log_1');
    expect(stored?.cleanedText, 'Shivani is my coworker.');
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
    expect(runner.prompts, hasLength(3));
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
}
