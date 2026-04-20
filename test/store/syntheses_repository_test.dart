import 'package:flutter_test/flutter_test.dart';
import 'package:voxsynth/asr/models/transcript.dart';
import 'package:voxsynth/capture/models/speech_segment.dart';
import 'package:voxsynth/embed/embedder.dart';
import 'package:voxsynth/llm/models/cleaned_transcript.dart';
import 'package:voxsynth/store/database_factory.dart';
import 'package:voxsynth/store/voice_log_repository.dart';

VoiceLogRepository _repo() {
  final db = openInMemoryAppDatabase();
  final embedder = FakeEmbedder();
  return VoiceLogRepository(
    db,
    embedder: embedder,
    audioFileDeleter: (_) async {},
  );
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
  group('VoiceLogRepository.insertSynthesis / listSyntheses', () {
    test('round-trip: insert then list returns the row', () async {
      final repo = _repo();
      final periodStart = DateTime.utc(2026, 4, 19);
      final periodEnd = DateTime.utc(2026, 4, 19, 23, 59, 59);
      final created = DateTime.utc(2026, 4, 20, 2);
      final idR = await repo.insertSynthesis(
        kind: 'daily_brief',
        periodStart: periodStart,
        periodEnd: periodEnd,
        payloadJson: '{"summary":"hi"}',
        createdAt: created,
      );
      expect(idR.isOk, isTrue);

      final listR = await repo.listSyntheses();
      expect(listR.isOk, isTrue);
      final rows = listR.okOrNull!;
      expect(rows, hasLength(1));
      expect(rows.single.kind, 'daily_brief');
      expect(rows.single.payloadJson, '{"summary":"hi"}');
      // DateTime columns round-trip as ms-since-epoch (local tz on
      // read, same as ChunkRecord.createdAt) — compare instants.
      expect(
        rows.single.periodStart.millisecondsSinceEpoch,
        periodStart.millisecondsSinceEpoch,
      );
      expect(
        rows.single.periodEnd.millisecondsSinceEpoch,
        periodEnd.millisecondsSinceEpoch,
      );
      expect(
        rows.single.createdAt.millisecondsSinceEpoch,
        created.millisecondsSinceEpoch,
      );
    });

    test('filters by kind', () async {
      final repo = _repo();
      await repo.insertSynthesis(
        kind: 'daily_brief',
        periodStart: DateTime.utc(2026, 4, 2),
        periodEnd: DateTime.utc(2026, 4, 2, 23, 59),
        payloadJson: '{}',
      );
      await repo.insertSynthesis(
        kind: 'weekly_themes',
        periodStart: DateTime.utc(2026, 4, 2),
        periodEnd: DateTime.utc(2026, 4, 8),
        payloadJson: '{}',
      );
      final daily = await repo.listSyntheses(kind: 'daily_brief');
      expect(daily.okOrNull, hasLength(1));
      expect(daily.okOrNull!.single.kind, 'daily_brief');
    });

    test('orders by createdAt DESC and respects limit', () async {
      final repo = _repo();
      for (var i = 0; i < 5; i++) {
        await repo.insertSynthesis(
          kind: 'daily_brief',
          periodStart: DateTime.utc(2026, 4, 2 + i),
          periodEnd: DateTime.utc(2026, 4, 2 + i, 23, 59),
          payloadJson: '{"i":$i}',
          createdAt: DateTime.utc(2026, 4, 10, i + 1),
        );
      }
      final listR = await repo.listSyntheses(limit: 3);
      expect(listR.okOrNull, hasLength(3));
      // Newest first → i=4, then i=3, then i=2.
      expect(listR.okOrNull![0].payloadJson, '{"i":4}');
      expect(listR.okOrNull![2].payloadJson, '{"i":2}');
    });

    test('filters by createdAt from/to range', () async {
      final repo = _repo();
      await repo.insertSynthesis(
        kind: 'daily_brief',
        periodStart: DateTime.utc(2026, 4, 2),
        periodEnd: DateTime.utc(2026, 4, 2),
        payloadJson: '{"old":true}',
        createdAt: DateTime.utc(2026, 3, 2),
      );
      await repo.insertSynthesis(
        kind: 'daily_brief',
        periodStart: DateTime.utc(2026, 4, 15),
        periodEnd: DateTime.utc(2026, 4, 15),
        payloadJson: '{"new":true}',
        createdAt: DateTime.utc(2026, 4, 15),
      );
      final listR = await repo.listSyntheses(
        from: DateTime.utc(2026, 4, 2),
        to: DateTime.utc(2026, 4, 30),
      );
      expect(listR.okOrNull, hasLength(1));
      expect(listR.okOrNull!.single.payloadJson, '{"new":true}');
    });
  });

  group('VoiceLogRepository.chunksInRange', () {
    test('returns only chunks inside the inclusive window', () async {
      final repo = _repo();
      await repo.ingest(
        recording: _rec('old', DateTime.utc(2026, 3, 2)),
        transcript: _tr('old note'),
        cleaned: _cl('old note text'),
      );
      await repo.ingest(
        recording: _rec('mid', DateTime.utc(2026, 4, 10)),
        transcript: _tr('middle note'),
        cleaned: _cl('middle note text'),
      );
      await repo.ingest(
        recording: _rec('new', DateTime.utc(2026, 5, 2)),
        transcript: _tr('new note'),
        cleaned: _cl('new note text'),
      );
      final r = await repo.chunksInRange(
        from: DateTime.utc(2026, 4, 2),
        to: DateTime.utc(2026, 4, 30),
      );
      expect(r.okOrNull, hasLength(1));
      expect(r.okOrNull!.single.logId.raw, 'mid');
    });

    test('deterministic ordering by (createdAt ASC, id ASC)', () async {
      final repo = _repo();
      // Ingest out-of-order to be sure the query sorts, not insertion.
      await repo.ingest(
        recording: _rec('b', DateTime.utc(2026, 4, 10, 12)),
        transcript: _tr('b'),
        cleaned: _cl('b body'),
      );
      await repo.ingest(
        recording: _rec('a', DateTime.utc(2026, 4, 10, 8)),
        transcript: _tr('a'),
        cleaned: _cl('a body'),
      );
      final r = await repo.chunksInRange(
        from: DateTime.utc(2026, 4, 10),
        to: DateTime.utc(2026, 4, 10, 23, 59),
      );
      final ids = r.okOrNull!.map((c) => c.logId.raw).toList();
      expect(ids, <String>['a', 'b']);
    });
  });
}
