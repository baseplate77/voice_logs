import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:voxsynth/asr/models/transcript.dart';
import 'package:voxsynth/capture/models/speech_segment.dart';
import 'package:voxsynth/embed/embedder.dart';
import 'package:voxsynth/llm/llm_runner.dart';
import 'package:voxsynth/llm/models/cleaned_transcript.dart';
import 'package:voxsynth/store/database_factory.dart';
import 'package:voxsynth/store/voice_log_repository.dart';
import 'package:voxsynth/synth/background/models/weekly_themes.dart';
import 'package:voxsynth/synth/background/weekly_themes_job.dart';

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
  group('WeeklyThemesJob.run', () {
    test('empty 7-day window → empty themes payload, no LLM call',
        () async {
      final repo = await _repo();
      final runner = await _runner(const <String>[]);
      final job = WeeklyThemesJob(
        repository: repo,
        runner: runner,
        clock: () => DateTime(2026, 4, 19, 12),
      );
      final r = await job.run();
      expect(r.isOk, isTrue);
      expect(runner.callCount, 0);
      expect(r.okOrNull!.themes.themes, isEmpty);
      expect(r.okOrNull!.themes.contradictions, isEmpty);
      expect(r.okOrNull!.themes.weekStart, '2026-04-13');
    });

    test('parses well-formed LLM output + persists', () async {
      final repo = await _repo();
      // Spread over the 7 days leading up to Apr 19.
      for (var i = 0; i < 4; i++) {
        await repo.ingest(
          recording: _rec('c$i', DateTime(2026, 4, 16 + (i % 4), 10)),
          transcript: _tr('pricing mention $i'),
          cleaned: _cl('pricing mention $i with body text'),
        );
      }
      final runner = await _runner(const <String>[
        '''
{
  "themes": [
    {
      "title": "Pricing",
      "summary": "Revisited pricing four times",
      "supporting_chunk_ids": [1, 2, 3, 4]
    }
  ],
  "contradictions": [
    {
      "earlier_position": "Flat rate",
      "later_position": "Tiered",
      "earlier_chunk_ids": [1],
      "later_chunk_ids": [4]
    }
  ]
}
''',
      ]);
      final job = WeeklyThemesJob(
        repository: repo,
        runner: runner,
        clock: () => DateTime(2026, 4, 19, 23),
      );
      final r = await job.run();
      final themes = r.okOrNull!.themes;
      expect(themes.themes, hasLength(1));
      expect(themes.themes.single.title, 'Pricing');
      expect(themes.contradictions, hasLength(1));
      expect(themes.contradictions.single.earlierPosition, 'Flat rate');
      // Persisted and round-trips.
      final list = (await repo.listSyntheses(kind: 'weekly_themes'))
          .okOrNull!;
      expect(list, hasLength(1));
      final decoded = WeeklyThemes.fromJson(
        jsonDecode(list.single.payloadJson) as Map<String, Object?>,
      );
      expect(decoded, themes);
    });

    test('malformed LLM JSON → empty fallback, still persisted',
        () async {
      final repo = await _repo();
      await repo.ingest(
        recording: _rec('a', DateTime(2026, 4, 18, 10)),
        transcript: _tr('n'),
        cleaned: _cl('note content goes here for the test'),
      );
      final runner = await _runner(const <String>['I refuse']);
      final job = WeeklyThemesJob(
        repository: repo,
        runner: runner,
        clock: () => DateTime(2026, 4, 19, 23),
      );
      final r = await job.run();
      expect(r.isOk, isTrue);
      expect(r.okOrNull!.themes.themes, isEmpty);
      final list = (await repo.listSyntheses(kind: 'weekly_themes'))
          .okOrNull!;
      expect(list, hasLength(1));
    });

    test('respects custom weekEnding argument', () async {
      final repo = await _repo();
      // A chunk from a week much earlier.
      await repo.ingest(
        recording: _rec('old', DateTime(2026, 3, 20, 10)),
        transcript: _tr('march note'),
        cleaned: _cl('march note goes here as body text'),
      );
      final runner = await _runner(const <String>[
        '{"themes":[],"contradictions":[]}',
      ]);
      final job = WeeklyThemesJob(
        repository: repo,
        runner: runner,
        clock: () => DateTime(2026, 4, 19, 23),
      );
      final r = await job.run(weekEnding: DateTime(2026, 3, 22, 23));
      expect(r.isOk, isTrue);
      // The clocked "today" (Apr 19) would have found no chunks; the
      // overridden March window sees the march note → LLM called once.
      expect(runner.callCount, 1);
      expect(r.okOrNull!.themes.weekStart, '2026-03-16');
    });
  });
}
