import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:voxsynth/asr/models/transcript.dart';
import 'package:voxsynth/capture/models/speech_segment.dart';
import 'package:voxsynth/embed/embedder.dart';
import 'package:voxsynth/llm/llm_runner.dart';
import 'package:voxsynth/llm/models/cleaned_transcript.dart';
import 'package:voxsynth/store/database_factory.dart';
import 'package:voxsynth/store/voice_log_repository.dart';
import 'package:voxsynth/synth/background/models/monthly_shifts.dart';
import 'package:voxsynth/synth/background/monthly_shifts_job.dart';

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
  group('MonthlyShiftsJob.run', () {
    test('empty corpus → placeholder payload, no LLM call', () async {
      final repo = await _repo();
      final runner = await _runner(const <String>[]);
      final job = MonthlyShiftsJob(
        repository: repo,
        runner: runner,
        clock: () => DateTime(2026, 4, 19, 12),
      );
      final r = await job.run();
      expect(r.isOk, isTrue);
      expect(runner.callCount, 0);
      expect(r.okOrNull!.shifts.headline,
          'No notable shifts this month.');
      expect(r.okOrNull!.shifts.shifts, isEmpty);
    });

    test('parses well-formed LLM output and persists', () async {
      final repo = await _repo();
      // 2 chunks in the prior window (~35 days ago), 2 in current.
      await repo.ingest(
        recording: _rec('p1', DateTime(2026, 3, 10, 10)),
        transcript: _tr('pricing flat'),
        cleaned: _cl('prior month: pricing flat structure'),
      );
      await repo.ingest(
        recording: _rec('p2', DateTime(2026, 3, 15, 10)),
        transcript: _tr('pricing flat 2'),
        cleaned: _cl('prior month: pricing flat confirmation'),
      );
      await repo.ingest(
        recording: _rec('c1', DateTime(2026, 4, 10, 10)),
        transcript: _tr('tiered pricing'),
        cleaned: _cl('current month: tiered pricing decided'),
      );
      await repo.ingest(
        recording: _rec('c2', DateTime(2026, 4, 15, 10)),
        transcript: _tr('tiered pricing 2'),
        cleaned: _cl('current month: tiered pricing validated'),
      );
      final runner = await _runner(const <String>[
        '''
{
  "headline": "Pricing model shifted from flat to tiered.",
  "shifts": [
    {
      "topic": "Pricing",
      "prior_summary": "Flat rate planned",
      "current_summary": "Tiered model decided",
      "prior_chunk_ids": [1, 2],
      "current_chunk_ids": [3, 4]
    }
  ]
}
''',
      ]);
      final job = MonthlyShiftsJob(
        repository: repo,
        runner: runner,
        clock: () => DateTime(2026, 4, 19, 23),
      );
      final r = await job.run();
      final shifts = r.okOrNull!.shifts;
      expect(shifts.headline,
          'Pricing model shifted from flat to tiered.');
      expect(shifts.shifts, hasLength(1));
      expect(shifts.shifts.single.topic, 'Pricing');
      expect(shifts.shifts.single.priorChunkIds, <int>[1, 2]);
      // Persistence + round-trip.
      final list = (await repo.listSyntheses(kind: 'monthly_shifts'))
          .okOrNull!;
      expect(list, hasLength(1));
      final decoded = MonthlyShifts.fromJson(
        jsonDecode(list.single.payloadJson) as Map<String, Object?>,
      );
      expect(decoded, shifts);
    });

    test('malformed LLM output → graceful fallback', () async {
      final repo = await _repo();
      await repo.ingest(
        recording: _rec('c1', DateTime(2026, 4, 10, 10)),
        transcript: _tr('note'),
        cleaned: _cl('current month note content here'),
      );
      final runner = await _runner(const <String>['not json']);
      final job = MonthlyShiftsJob(
        repository: repo,
        runner: runner,
        clock: () => DateTime(2026, 4, 19, 23),
      );
      final r = await job.run();
      expect(r.isOk, isTrue);
      expect(r.okOrNull!.shifts.headline,
          'No notable shifts this month.');
    });

    test('respects custom monthEnding override', () async {
      final repo = await _repo();
      // Only add chunks inside an overridden Jan window.
      await repo.ingest(
        recording: _rec('jan', DateTime(2026, 1, 20, 10)),
        transcript: _tr('jan'),
        cleaned: _cl('jan note content here for body'),
      );
      final runner = await _runner(const <String>[
        '{"headline":"jan things","shifts":[]}',
      ]);
      final job = MonthlyShiftsJob(
        repository: repo,
        runner: runner,
        clock: () => DateTime(2026, 4, 19, 23),
      );
      final r = await job.run(monthEnding: DateTime(2026, 1, 31, 23));
      expect(r.isOk, isTrue);
      expect(runner.callCount, 1);
      expect(r.okOrNull!.shifts.headline, 'jan things');
    });
  });
}
