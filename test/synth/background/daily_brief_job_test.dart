import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:voxsynth/asr/models/transcript.dart';
import 'package:voxsynth/capture/models/speech_segment.dart';
import 'package:voxsynth/core/errors.dart';
import 'package:voxsynth/core/result.dart';
import 'package:voxsynth/embed/embedder.dart';
import 'package:voxsynth/llm/llm_runner.dart';
import 'package:voxsynth/llm/models/cleaned_transcript.dart';
import 'package:voxsynth/store/database_factory.dart';
import 'package:voxsynth/store/voice_log_repository.dart';
import 'package:voxsynth/synth/background/daily_brief_job.dart';
import 'package:voxsynth/synth/background/models/daily_brief.dart';

Future<VoiceLogRepository> _repo() async {
  final db = openInMemoryAppDatabase();
  await db.customSelect('SELECT 1').get();
  final embedder = FakeEmbedder();
  await embedder.load();
  return VoiceLogRepository(
    db,
    embedder: embedder,
    audioFileDeleter: (_) async {},
  );
}

Future<FakeLlmRunner> _runner(List<String> responses) async {
  final r = FakeLlmRunner(responses: responses);
  await r.load();
  return r;
}

RecordingHandle _rec(String id, DateTime at) => RecordingHandle(
      id: id,
      audioFilePath: '/tmp/$id.wav',
      durationMs: 10_000,
      startedAt: at,
    );

Transcript _tr(String text) =>
    Transcript(text: text, words: const <Word>[], detectedLanguage: 'en');

CleanedTranscript _cl(String text) => CleanedTranscript(
      text: text,
      chunks: <TopicChunk>[
        TopicChunk(
          text: text,
          startChar: 0,
          endChar: text.length,
          topicHint: 'generic',
        ),
      ],
      entities: const <Entity>[],
      tags: const <String>[],
    );

void main() {
  group('DailyBriefJob.run', () {
    test('empty day → placeholder brief, no LLM call, still persisted',
        () async {
      final repo = await _repo();
      final runner = await _runner(const <String>[]);
      final job = DailyBriefJob(
        repository: repo,
        runner: runner,
        clock: () => DateTime(2026, 4, 19, 12),
      );
      final r = await job.run();
      expect(r.isOk, isTrue, reason: '${r.errOrNull}');
      expect(runner.callCount, 0);
      final out = r.okOrNull!;
      expect(out.brief.summary, 'No activity on this day.');
      expect(out.brief.actionItems, isEmpty);
      expect(out.brief.keyMoments, isEmpty);
      expect(out.brief.date, '2026-04-19');
      // Persisted row exists.
      final list = await repo.listSyntheses(kind: 'daily_brief');
      expect(list.okOrNull, hasLength(1));
    });

    test('populated day → parses LLM JSON and persists the brief',
        () async {
      final repo = await _repo();
      await repo.ingest(
        recording: _rec('a', DateTime(2026, 4, 19, 10)),
        transcript: _tr('pricing decision'),
        cleaned: _cl('decided on tiered pricing structure'),
      );
      await repo.ingest(
        recording: _rec('b', DateTime(2026, 4, 19, 14)),
        transcript: _tr('follow up TODO'),
        cleaned: _cl('need to send the proposal to Alice by Friday'),
      );
      // Fake LLM returns a well-formed JSON brief. source_chunk_ids
      // don't have to match actual chunk ids for the test — the job
      // doesn't validate them.
      final runner = await _runner(const <String>[
        '''
{
  "summary": "Pricing and proposal.",
  "action_items": [
    {"text": "Send proposal to Alice", "source_chunk_ids": [2]}
  ],
  "key_moments": [
    {"description": "Tiered pricing decided", "source_chunk_ids": [1]}
  ]
}
''',
      ]);
      final job = DailyBriefJob(
        repository: repo,
        runner: runner,
        clock: () => DateTime(2026, 4, 19, 23),
      );
      final r = await job.run();
      expect(r.isOk, isTrue, reason: '${r.errOrNull}');
      final brief = r.okOrNull!.brief;
      expect(brief.summary, 'Pricing and proposal.');
      expect(brief.actionItems, hasLength(1));
      expect(brief.actionItems.single.text, 'Send proposal to Alice');
      expect(brief.keyMoments, hasLength(1));
      expect(brief.keyMoments.single.description,
          'Tiered pricing decided');
      expect(runner.callCount, 1);
      // Persisted with correct kind + recoverable via fromJson.
      final list = (await repo.listSyntheses(kind: 'daily_brief'))
          .okOrNull!;
      expect(list, hasLength(1));
      final decoded = DailyBrief.fromJson(
        jsonDecode(list.single.payloadJson) as Map<String, Object?>,
      );
      expect(decoded, brief);
    });

    test('malformed LLM JSON → graceful fallback, still persists',
        () async {
      final repo = await _repo();
      await repo.ingest(
        recording: _rec('a', DateTime(2026, 4, 19, 10)),
        transcript: _tr('some note'),
        cleaned: _cl('some note content here'),
      );
      final runner = await _runner(const <String>['not json at all']);
      final job = DailyBriefJob(
        repository: repo,
        runner: runner,
        clock: () => DateTime(2026, 4, 19, 23),
      );
      final r = await job.run();
      expect(r.isOk, isTrue);
      expect(
        r.okOrNull!.brief.summary,
        'No brief could be generated for this day.',
      );
      final list = (await repo.listSyntheses(kind: 'daily_brief'))
          .okOrNull!;
      expect(list, hasLength(1));
    });

    test('strips markdown code fences around JSON', () async {
      final repo = await _repo();
      await repo.ingest(
        recording: _rec('a', DateTime(2026, 4, 19, 10)),
        transcript: _tr('note'),
        cleaned: _cl('note content goes here'),
      );
      final runner = await _runner(const <String>[
        '```json\n{"summary": "Fine.", "action_items": [], "key_moments": []}\n```',
      ]);
      final job = DailyBriefJob(
        repository: repo,
        runner: runner,
        clock: () => DateTime(2026, 4, 19, 23),
      );
      final r = await job.run();
      expect(r.okOrNull!.brief.summary, 'Fine.');
    });

    test('uses low temperature for idempotency', () async {
      final repo = await _repo();
      await repo.ingest(
        recording: _rec('a', DateTime(2026, 4, 19, 10)),
        transcript: _tr('note'),
        cleaned: _cl('note content goes here'),
      );
      double? seenTemp;
      final recorder = _TempRecorder(
        responses: const <String>[
          '{"summary":"x","action_items":[],"key_moments":[]}'
        ],
        onTemp: (t) => seenTemp = t,
      );
      await recorder.load();
      final job = DailyBriefJob(
        repository: repo,
        runner: recorder,
        clock: () => DateTime(2026, 4, 19, 23),
      );
      await job.run();
      expect(seenTemp, kBackgroundJobTemperature);
    });

    test('respects custom dayOf argument', () async {
      final repo = await _repo();
      // Chunk on April 15. Default "today" clock would look at Apr 19.
      await repo.ingest(
        recording: _rec('a', DateTime(2026, 4, 15, 10)),
        transcript: _tr('old note'),
        cleaned: _cl('old note text for apr 15'),
      );
      final runner = await _runner(const <String>[
        '{"summary":"apr15","action_items":[],"key_moments":[]}'
      ]);
      final job = DailyBriefJob(
        repository: repo,
        runner: runner,
        clock: () => DateTime(2026, 4, 19, 23),
      );
      final r = await job.run(dayOf: DateTime(2026, 4, 15, 10));
      expect(r.okOrNull!.brief.date, '2026-04-15');
      expect(runner.callCount, 1);
    });
  });
}

/// Captures the `temperatureOverride` arg on generateSync for the
/// idempotency test.
class _TempRecorder extends FakeLlmRunner {
  _TempRecorder({
    required super.responses,
    required this.onTemp,
  });

  final void Function(double?) onTemp;

  @override
  Future<Result<String, AppError>> generateSync(
    String prompt, {
    double? temperatureOverride,
  }) async {
    onTemp(temperatureOverride);
    return super.generateSync(
      prompt,
      temperatureOverride: temperatureOverride,
    );
  }
}
