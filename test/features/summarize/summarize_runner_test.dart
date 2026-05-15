import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voxsynth/core/db/database.dart';
import 'package:voxsynth/core/db/repositories/log_summary_repository.dart';
import 'package:voxsynth/core/db/repositories/voice_log_repository.dart';
import 'package:voxsynth/core/result.dart';
import 'package:voxsynth/core/worker/job_handler.dart';
import 'package:voxsynth/features/refine/llm_runner.dart';
import 'package:voxsynth/features/summarize/summarize_runner.dart';

const _validSummary = '''
{
  "one_liner": "Discussed app launch planning with Raj.",
  "bullets": [
    "Investor deck needs updates.",
    "Launch target is next Friday.",
    "Raj will review pricing."
  ],
  "people_projects": ["Raj"],
  "decisions": ["Launch target set to next Friday."],
  "follow_ups": ["Update investor deck.", "Send Raj pricing draft."]
}
''';

class _ScriptedRunner implements LlmRunner {
  _ScriptedRunner(this.responses);
  final List<String> responses;
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

Future<
  ({
    VoxSynthDatabase db,
    VoiceLogRepository logs,
    LogSummaryRepository summaries,
  })
>
_setup({
  String rawTranscript = 'raw transcript',
  String? cleanedText = 'I talked to Raj about the launch.',
}) async {
  final db = VoxSynthDatabase(NativeDatabase.memory());
  final logs = VoiceLogRepository(db);
  final summaries = LogSummaryRepository(db);
  await logs.insertRecorded(
    id: 'log_1',
    createdAt: DateTime(2026, 5, 9),
    durationMs: 1000,
    audioPath: 'audio/log_1.wav',
    rawTranscript: rawTranscript,
  );
  if (cleanedText != null) {
    await logs.markRefined(id: 'log_1', cleanedText: cleanedText);
  }
  return (db: db, logs: logs, summaries: summaries);
}

void main() {
  test(
    'SummarizeRunner persists a parsed summary on the first response',
    () async {
      final ctx = await _setup();
      addTearDown(ctx.db.close);

      final runner = _ScriptedRunner([_validSummary]);
      final handler = SummarizeRunner(
        runner: runner,
        voiceLogs: ctx.logs,
        summaries: ctx.summaries,
      );

      final outcome = await handler.handle(
        const JobContext(jobId: 'job_1', logId: 'log_1', attempts: 0),
      );
      expect(outcome.isOk, isTrue);
      expect((outcome as Ok).value, isA<JobSucceeded>());
      expect(runner.prompts, hasLength(1));

      final stored = await ctx.summaries.findByLogId('log_1');
      expect(stored, isNotNull);
      expect(stored!.oneLiner, 'Discussed app launch planning with Raj.');
      expect(stored.bullets, hasLength(3));
      expect(stored.peopleProjects, ['Raj']);
      expect(stored.followUps, hasLength(2));
    },
  );

  test(
    'SummarizeRunner retries when the first response fails to parse',
    () async {
      final ctx = await _setup();
      addTearDown(ctx.db.close);

      final runner = _ScriptedRunner(['not json at all', _validSummary]);
      final handler = SummarizeRunner(
        runner: runner,
        voiceLogs: ctx.logs,
        summaries: ctx.summaries,
      );

      final outcome = await handler.handle(
        const JobContext(jobId: 'job_1', logId: 'log_1', attempts: 0),
      );
      expect(outcome.isOk, isTrue);
      expect(runner.prompts, hasLength(2));
      final stored = await ctx.summaries.findByLogId('log_1');
      expect(stored, isNotNull);
    },
  );

  test(
    'SummarizeRunner is best-effort when both attempts fail to parse',
    () async {
      final ctx = await _setup();
      addTearDown(ctx.db.close);

      final runner = _ScriptedRunner(['garbage one', 'garbage two']);
      final handler = SummarizeRunner(
        runner: runner,
        voiceLogs: ctx.logs,
        summaries: ctx.summaries,
      );

      final outcome = await handler.handle(
        const JobContext(jobId: 'job_1', logId: 'log_1', attempts: 0),
      );
      expect(outcome.isOk, isTrue);
      expect((outcome as Ok).value, isA<JobSucceeded>());
      final stored = await ctx.summaries.findByLogId('log_1');
      expect(stored, isNull);
    },
  );

  test(
    'SummarizeRunner skips empty transcripts without calling the LLM',
    () async {
      final ctx = await _setup(rawTranscript: '   ', cleanedText: null);
      addTearDown(ctx.db.close);

      final runner = _ScriptedRunner([]);
      final handler = SummarizeRunner(
        runner: runner,
        voiceLogs: ctx.logs,
        summaries: ctx.summaries,
      );

      final outcome = await handler.handle(
        const JobContext(jobId: 'job_1', logId: 'log_1', attempts: 0),
      );
      expect(outcome.isOk, isTrue);
      expect(runner.prompts, isEmpty);
      expect(await ctx.summaries.findByLogId('log_1'), isNull);
    },
  );

  test(
    'SummarizeRunner reports log-not-found as a permanent failure',
    () async {
      final ctx = await _setup();
      addTearDown(ctx.db.close);

      final runner = _ScriptedRunner([_validSummary]);
      final handler = SummarizeRunner(
        runner: runner,
        voiceLogs: ctx.logs,
        summaries: ctx.summaries,
      );

      final outcome = await handler.handle(
        const JobContext(jobId: 'job_1', logId: 'missing', attempts: 0),
      );
      expect(outcome.isOk, isTrue);
      expect((outcome as Ok).value, isA<JobFailedPermanently>());
      expect(runner.prompts, isEmpty);
    },
  );
}
