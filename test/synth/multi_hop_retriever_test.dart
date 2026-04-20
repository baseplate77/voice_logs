import 'package:flutter_test/flutter_test.dart';
import 'package:voxsynth/asr/models/transcript.dart';
import 'package:voxsynth/capture/models/speech_segment.dart';
import 'package:voxsynth/embed/embedder.dart';
import 'package:voxsynth/llm/llm_runner.dart';
import 'package:voxsynth/llm/models/cleaned_transcript.dart';
import 'package:voxsynth/retrieve/hybrid_retriever.dart';
import 'package:voxsynth/retrieve/query_expander.dart';
import 'package:voxsynth/retrieve/reranker.dart';
import 'package:voxsynth/store/app_database.dart';
import 'package:voxsynth/store/database_factory.dart';
import 'package:voxsynth/store/vector_index.dart';
import 'package:voxsynth/store/voice_log_repository.dart';
import 'package:voxsynth/synth/multi_hop_retriever.dart';

/// Matches _Harness in hybrid_retriever_test but expander/reranker
/// return constant "no paraphrases / uniform scores" payloads so the
/// multi-hop retriever sees week membership as the only differentiator.
class _Harness {
  _Harness({
    required this.db,
    required this.repo,
    required this.retriever,
  });

  final AppDatabase db;
  final VoiceLogRepository repo;
  final HybridRetriever retriever;

  static Future<_Harness> create({
    required DateTime Function() clock,
  }) async {
    final db = openInMemoryAppDatabase();
    await db.customSelect('SELECT 1').get();
    final embedder = FakeEmbedder();
    await embedder.load();
    final vectorIndex = InMemoryVectorIndex();
    final repo = VoiceLogRepository(
      db,
      embedder: embedder,
      vectorIndex: vectorIndex,
      audioFileDeleter: (_) async {},
    );
    // Expander: always returns "no paraphrases". Cycles on exhaustion
    // via FakeLlmRunner semantics so we can call retrieve() N times.
    final expanderRunner = FakeLlmRunner(
      responses: const <String>['{"paraphrases":[],"entities":[]}'],
    );
    await expanderRunner.load();
    // Reranker: uniform score so rerank doesn't override the
    // within-week ordering.
    final rerankerRunner = FakeLlmRunner(
      responses: const <String>['{"C1": 5, "C2": 5, "C3": 5, "C4": 5, "C5": 5}'],
    );
    await rerankerRunner.load();
    final retriever = HybridRetriever(
      repository: repo,
      embedder: embedder,
      queryExpander: QueryExpander(runner: expanderRunner),
      reranker: Reranker(runner: rerankerRunner),
      clock: clock,
    );
    return _Harness(db: db, repo: repo, retriever: retriever);
  }

  Future<void> close() async => db.close();
}

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

RecordingHandle _rec(String id, DateTime at) => RecordingHandle(
      id: id,
      audioFilePath: '/tmp/$id.wav',
      durationMs: 10_000,
      startedAt: at,
    );

void main() {
  // Pin "now" to a Sunday so weeks that wrap it are well-defined.
  // 2026-04-19 is a Sunday (weekday = 7).
  DateTime now() => DateTime.utc(2026, 4, 19, 12);

  group('MultiHopRetriever.isoWeekStart', () {
    test('Monday normalises to itself at 00:00 UTC', () {
      final mon = DateTime.utc(2026, 4, 13, 15, 30); // Monday 15:30
      final ws = MultiHopRetriever.isoWeekStart(mon);
      expect(ws, DateTime.utc(2026, 4, 13));
    });

    test('Sunday rolls back to the prior Monday', () {
      final sun = DateTime.utc(2026, 4, 19, 23, 59);
      final ws = MultiHopRetriever.isoWeekStart(sun);
      expect(ws, DateTime.utc(2026, 4, 13));
    });

    test('different days in the same week share a weekStart', () {
      final wed = DateTime.utc(2026, 4, 15, 8);
      final fri = DateTime.utc(2026, 4, 17, 20);
      expect(
        MultiHopRetriever.isoWeekStart(wed),
        MultiHopRetriever.isoWeekStart(fri),
      );
    });

    test('local times normalise via UTC', () {
      final localSun = DateTime(2026, 4, 19, 23, 59);
      final ws = MultiHopRetriever.isoWeekStart(localSun);
      // UTC conversion may shift this — the assertion is only that the
      // result is itself a Monday 00:00 UTC.
      expect(ws.weekday, DateTime.monday);
      expect(ws.hour, 0);
      expect(ws.minute, 0);
    });
  });

  group('MultiHopRetriever.retrieveTemporal', () {
    test('empty query short-circuits to empty clusters', () async {
      final h = await _Harness.create(clock: now);
      try {
        final r = await MultiHopRetriever(retriever: h.retriever)
            .retrieveTemporal('   ');
        expect(r.isOk, isTrue);
        expect(r.okOrNull, isEmpty);
      } finally {
        await h.close();
      }
    });

    test('empty corpus returns empty clusters', () async {
      final h = await _Harness.create(clock: now);
      try {
        final r = await MultiHopRetriever(retriever: h.retriever)
            .retrieveTemporal('pricing');
        expect(r.isOk, isTrue);
        expect(r.okOrNull, isEmpty);
      } finally {
        await h.close();
      }
    });

    test('clusters hits by ISO week and orders chronologically',
        () async {
      final h = await _Harness.create(clock: now);
      try {
        // Three weeks leading up to "now" (Sunday 2026-04-19):
        //   Week A: 2026-03-30..04-05 (≥2 hits → densified)
        //   Week B: 2026-04-06..04-12 (1 hit → dropped)
        //   Week C: 2026-04-13..04-19 (≥2 hits → densified)
        await h.repo.ingest(
          recording: _rec('a1', DateTime.utc(2026, 4, 1, 10)),
          transcript: _tr('pricing revisit one'),
          cleaned: _cl('pricing revisit one with detail'),
        );
        await h.repo.ingest(
          recording: _rec('a2', DateTime.utc(2026, 4, 3, 10)),
          transcript: _tr('pricing revisit two'),
          cleaned: _cl('pricing revisit two with extras'),
        );
        await h.repo.ingest(
          recording: _rec('b1', DateTime.utc(2026, 4, 8, 10)),
          transcript: _tr('pricing lonely middle week'),
          cleaned: _cl('pricing lonely middle week note'),
        );
        await h.repo.ingest(
          recording: _rec('c1', DateTime.utc(2026, 4, 14, 10)),
          transcript: _tr('pricing week of the demo'),
          cleaned: _cl('pricing week of the demo final'),
        );
        await h.repo.ingest(
          recording: _rec('c2', DateTime.utc(2026, 4, 16, 10)),
          transcript: _tr('pricing follow up before launch'),
          cleaned: _cl('pricing follow up before launch decided'),
        );

        final r = await MultiHopRetriever(retriever: h.retriever)
            .retrieveTemporal('pricing');
        expect(r.isOk, isTrue, reason: '${r.errOrNull}');
        final clusters = r.okOrNull!;
        expect(clusters, hasLength(2));
        // Chronological ordering.
        expect(
          clusters.first.weekStart.isBefore(clusters.last.weekStart),
          isTrue,
        );
        // First cluster covers Week A (Monday 2026-03-30).
        expect(clusters.first.weekStart, DateTime.utc(2026, 3, 30));
        // Second cluster covers Week C (Monday 2026-04-13).
        expect(clusters.last.weekStart, DateTime.utc(2026, 4, 13));
        // Every chunk in a cluster falls inside that week.
        for (final c in clusters) {
          final end = c.weekStart.add(const Duration(days: 7));
          for (final hit in c.chunks) {
            expect(
              hit.chunk.createdAt.isAfter(
                c.weekStart.subtract(const Duration(milliseconds: 1)),
              ),
              isTrue,
            );
            expect(hit.chunk.createdAt.isBefore(end), isTrue);
          }
        }
      } finally {
        await h.close();
      }
    });

    test('single-hit weeks drop below the min-hits threshold',
        () async {
      final h = await _Harness.create(clock: now);
      try {
        // One hit per week → every week fails the min=2 filter.
        await h.repo.ingest(
          recording: _rec('w1', DateTime.utc(2026, 4, 1, 10)),
          transcript: _tr('pricing single hit week one'),
          cleaned: _cl('pricing single hit week one only'),
        );
        await h.repo.ingest(
          recording: _rec('w2', DateTime.utc(2026, 4, 8, 10)),
          transcript: _tr('pricing single hit week two'),
          cleaned: _cl('pricing single hit week two only'),
        );
        final r = await MultiHopRetriever(retriever: h.retriever)
            .retrieveTemporal('pricing');
        expect(r.isOk, isTrue);
        expect(r.okOrNull, isEmpty);
      } finally {
        await h.close();
      }
    });

    test('respects a custom perWeekLimit', () async {
      final h = await _Harness.create(clock: now);
      try {
        // Five hits in the same week.
        for (var i = 0; i < 5; i++) {
          await h.repo.ingest(
            recording: _rec('r$i', DateTime.utc(2026, 4, 14 + (i % 5), 10)),
            transcript: _tr('pricing note $i'),
            cleaned: _cl('pricing note $i with more body text'),
          );
        }
        final r = await MultiHopRetriever(retriever: h.retriever)
            .retrieveTemporal('pricing', perWeekLimit: 2);
        expect(r.isOk, isTrue);
        final clusters = r.okOrNull!;
        expect(clusters, hasLength(1));
        expect(clusters.single.chunks, hasLength(2));
      } finally {
        await h.close();
      }
    });

    test('custom broadLimit caps first-hop candidates', () async {
      final h = await _Harness.create(clock: now);
      try {
        for (var i = 0; i < 6; i++) {
          await h.repo.ingest(
            recording: _rec('r$i', DateTime.utc(2026, 4, 14 + (i % 5), 10)),
            transcript: _tr('pricing chunk $i here'),
            cleaned: _cl('pricing chunk $i here for indexing'),
          );
        }
        // broadLimit=1 → only one chunk makes it into clustering, so
        // the single-hit week gets dropped.
        final r = await MultiHopRetriever(retriever: h.retriever)
            .retrieveTemporal('pricing', broadLimit: 1);
        expect(r.isOk, isTrue);
        expect(r.okOrNull, isEmpty);
      } finally {
        await h.close();
      }
    });
  });
}
