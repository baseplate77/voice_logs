// ignore_for_file: avoid_redundant_argument_values

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voxsynth/core/db/database.dart';
import 'package:voxsynth/core/db/repositories/log_summary_repository.dart';
import 'package:voxsynth/core/db/repositories/voice_log_repository.dart';
import 'package:voxsynth/core/result.dart';
import 'package:voxsynth/core/worker/job_handler.dart';
import 'package:voxsynth/features/digest/digest_runner.dart';
import 'package:voxsynth/features/refine/llm_runner.dart';

const _validDaily = '''
{
  "one_liner": "Productive day shipping the digest feature.",
  "what_happened": [
    "Designed the Phase 11 pipeline.",
    "Wired up the worker handler."
  ],
  "people_mentioned": ["Raj"],
  "tasks_created": ["Write the runner tests."],
  "decisions": ["On-demand only for v1."],
  "mood_theme": "focused"
}
''';

const _validWeekly = '''
{
  "one_liner": "Steady progress on shipping.",
  "main_themes": ["Phase 11 digests", "Polish"],
  "project_progress": ["Digest pipeline scaffolded."],
  "repeated_concerns": ["Gemma JSON drift."],
  "unfinished_tasks": ["Integration test."]
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
_setupDb() async {
  final db = VoxSynthDatabase(NativeDatabase.memory());
  final logs = VoiceLogRepository(db);
  final summaries = LogSummaryRepository(db);
  return (db: db, logs: logs, summaries: summaries);
}

Future<void> _seedLog(
  VoiceLogRepository logs, {
  required String id,
  required DateTime createdAt,
  String raw = 'raw transcript',
  String? cleaned = 'I talked to Raj about shipping the digest feature.',
}) async {
  await logs.insertRecorded(
    id: id,
    createdAt: createdAt,
    durationMs: 1000,
    audioPath: 'audio/$id.wav',
    rawTranscript: raw,
  );
  if (cleaned != null) {
    await logs.markRefined(id: id, cleanedText: cleaned);
  }
}

void main() {
  group('DigestTarget', () {
    test('today() builds a daily target keyed on local date', () {
      final target = DigestTarget.today(now: DateTime(2026, 5, 15, 13, 37));
      expect(target.kind, DigestKind.daily);
      expect(target.windowKey, '2026-05-15');
      expect(target.wire, 'daily:2026-05-15');
      final window = target.window();
      expect(window.start, DateTime(2026, 5, 15));
      expect(window.end, DateTime(2026, 5, 16));
    });

    test('weekEndingOn() spans 7 days inclusive', () {
      final target = DigestTarget.weekEndingOn(endDay: DateTime(2026, 5, 15));
      expect(target.kind, DigestKind.weekly);
      expect(target.windowKey, '2026-05-09');
      expect(target.label, '2026-05-09 to 2026-05-15');
      final window = target.window();
      expect(window.start, DateTime(2026, 5, 9));
      expect(window.end, DateTime(2026, 5, 16));
    });

    test('tryParse() round-trips wire ids', () {
      final daily = DigestTarget.tryParse('daily:2026-05-15');
      expect(daily, isNotNull);
      expect(daily!.kind, DigestKind.daily);
      expect(daily.windowKey, '2026-05-15');

      final weekly = DigestTarget.tryParse('weekly:2026-05-09');
      expect(weekly, isNotNull);
      expect(weekly!.kind, DigestKind.weekly);
      expect(weekly.label, '2026-05-09 to 2026-05-15');
    });

    test('tryParse() rejects malformed ids', () {
      expect(DigestTarget.tryParse('monthly:2026-05-01'), isNull);
      expect(DigestTarget.tryParse('daily:not-a-date'), isNull);
      expect(DigestTarget.tryParse('weekly:'), isNull);
      expect(DigestTarget.tryParse('plain-string'), isNull);
    });
  });

  group('DigestRunner', () {
    test('persists a daily digest on the first response', () async {
      final ctx = await _setupDb();
      addTearDown(ctx.db.close);
      await _seedLog(
        ctx.logs,
        id: 'log_1',
        createdAt: DateTime(2026, 5, 15, 9, 0),
      );

      final runner = _ScriptedRunner([_validDaily]);
      final handler = DigestRunner(
        runner: runner,
        voiceLogs: ctx.logs,
        summaries: ctx.summaries,
      );

      final target = DigestTarget.today(now: DateTime(2026, 5, 15, 23, 59));
      final outcome = await handler.handle(
        JobContext(jobId: 'job_1', logId: target.wire, attempts: 0),
      );
      expect(outcome.isOk, isTrue);
      expect((outcome as Ok).value, isA<JobSucceeded>());
      expect(runner.prompts, hasLength(1));

      final stored = await ctx.summaries.findDigest(
        kind: target.kind,
        windowKey: target.windowKey,
      );
      expect(stored, isNotNull);
      expect(stored!.bullets, hasLength(2));
      expect(stored.topics, ['Raj']);
      expect(stored.mood, 'focused');
    });

    test(
      'retries with stricter prompt when the first response is garbled',
      () async {
        final ctx = await _setupDb();
        addTearDown(ctx.db.close);
        await _seedLog(
          ctx.logs,
          id: 'log_1',
          createdAt: DateTime(2026, 5, 15, 9, 0),
        );

        final runner = _ScriptedRunner(['not json', _validDaily]);
        final handler = DigestRunner(
          runner: runner,
          voiceLogs: ctx.logs,
          summaries: ctx.summaries,
        );

        final target = DigestTarget.today(now: DateTime(2026, 5, 15));
        final outcome = await handler.handle(
          JobContext(jobId: 'job_1', logId: target.wire, attempts: 0),
        );
        expect(outcome.isOk, isTrue);
        expect(runner.prompts, hasLength(2));
        final stored = await ctx.summaries.findDigest(
          kind: target.kind,
          windowKey: target.windowKey,
        );
        expect(stored, isNotNull);
      },
    );

    test('is best-effort when both attempts fail to parse', () async {
      final ctx = await _setupDb();
      addTearDown(ctx.db.close);
      await _seedLog(
        ctx.logs,
        id: 'log_1',
        createdAt: DateTime(2026, 5, 15, 9, 0),
      );

      final runner = _ScriptedRunner(['garbage one', 'garbage two']);
      final handler = DigestRunner(
        runner: runner,
        voiceLogs: ctx.logs,
        summaries: ctx.summaries,
      );

      final target = DigestTarget.today(now: DateTime(2026, 5, 15));
      final outcome = await handler.handle(
        JobContext(jobId: 'job_1', logId: target.wire, attempts: 0),
      );
      expect(outcome.isOk, isTrue);
      expect((outcome as Ok).value, isA<JobSucceeded>());
      final stored = await ctx.summaries.findDigest(
        kind: target.kind,
        windowKey: target.windowKey,
      );
      expect(stored, isNull);
    });

    test('skips empty windows without invoking the LLM', () async {
      final ctx = await _setupDb();
      addTearDown(ctx.db.close);
      // Seed a log outside the target window.
      await _seedLog(
        ctx.logs,
        id: 'log_1',
        createdAt: DateTime(2026, 5, 14, 9, 0),
      );

      final runner = _ScriptedRunner([_validDaily]);
      final handler = DigestRunner(
        runner: runner,
        voiceLogs: ctx.logs,
        summaries: ctx.summaries,
      );

      final target = DigestTarget.today(now: DateTime(2026, 5, 15));
      final outcome = await handler.handle(
        JobContext(jobId: 'job_1', logId: target.wire, attempts: 0),
      );
      expect(outcome.isOk, isTrue);
      expect(runner.prompts, isEmpty);
      final stored = await ctx.summaries.findDigest(
        kind: target.kind,
        windowKey: target.windowKey,
      );
      expect(stored, isNull);
    });

    test('fails permanently when the digest target is unparseable', () async {
      final ctx = await _setupDb();
      addTearDown(ctx.db.close);
      final runner = _ScriptedRunner([]);
      final handler = DigestRunner(
        runner: runner,
        voiceLogs: ctx.logs,
        summaries: ctx.summaries,
      );

      final outcome = await handler.handle(
        const JobContext(
          jobId: 'job_1',
          logId: 'not-a-digest-target',
          attempts: 0,
        ),
      );
      expect(outcome.isOk, isTrue);
      expect((outcome as Ok).value, isA<JobFailedPermanently>());
      expect(runner.prompts, isEmpty);
    });

    test('handles weekly windows across seven days', () async {
      final ctx = await _setupDb();
      addTearDown(ctx.db.close);
      for (var i = 0; i < 3; i++) {
        await _seedLog(
          ctx.logs,
          id: 'log_$i',
          createdAt: DateTime(2026, 5, 10 + i, 9, 0),
          cleaned: 'Day ${10 + i} log about the digest rollout.',
        );
      }

      final runner = _ScriptedRunner([_validWeekly]);
      final handler = DigestRunner(
        runner: runner,
        voiceLogs: ctx.logs,
        summaries: ctx.summaries,
      );

      final target = DigestTarget.weekEndingOn(endDay: DateTime(2026, 5, 15));
      final outcome = await handler.handle(
        JobContext(jobId: 'job_1', logId: target.wire, attempts: 0),
      );
      expect(outcome.isOk, isTrue);
      final stored = await ctx.summaries.findDigest(
        kind: target.kind,
        windowKey: target.windowKey,
      );
      expect(stored, isNotNull);
      expect(stored!.kind, DigestKind.weekly);
      expect(stored.bullets, hasLength(2));
      expect(stored.mood, isNull);
    });
  });
}
