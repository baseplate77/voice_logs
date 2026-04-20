import 'package:flutter_test/flutter_test.dart';
import 'package:voxsynth/asr/models/transcript.dart';
import 'package:voxsynth/capture/models/speech_segment.dart';
import 'package:voxsynth/embed/embedder.dart';
import 'package:voxsynth/llm/llm_runner.dart';
import 'package:voxsynth/llm/models/cleaned_transcript.dart';
import 'package:voxsynth/retrieve/hybrid_retriever.dart';
import 'package:voxsynth/retrieve/models/ranked_chunk.dart';
import 'package:voxsynth/retrieve/query_expander.dart';
import 'package:voxsynth/retrieve/reranker.dart';
import 'package:voxsynth/store/app_database.dart';
import 'package:voxsynth/store/database_factory.dart';
import 'package:voxsynth/store/vector_index.dart';
import 'package:voxsynth/store/voice_log_repository.dart';

/// Harness with an in-memory store + in-memory vector index + scripted
/// LLMs for the expander/reranker. Owns lifecycle so tests can `close`
/// cleanly.
class _Harness {
  _Harness({
    required this.db,
    required this.repo,
    required this.retriever,
    required this.embedder,
  });

  final AppDatabase db;
  final VoiceLogRepository repo;
  final HybridRetriever retriever;
  final FakeEmbedder embedder;

  static Future<_Harness> create({
    required List<String> expanderScript,
    required List<String> rerankerScript,
    DateTime Function()? clock,
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
    // Fake runners can't script per-method, so we rebuild the harness
    // with distinct runners for expander vs reranker.
    final expanderRunner = _buildResponsesOnlyRunner(expanderScript);
    await expanderRunner.load();
    final rerankerRunner = _buildResponsesOnlyRunner(rerankerScript);
    await rerankerRunner.load();
    final retriever = HybridRetriever(
      repository: repo,
      embedder: embedder,
      queryExpander: QueryExpander(runner: expanderRunner),
      reranker: Reranker(runner: rerankerRunner),
      clock: clock,
    );
    return _Harness(
      db: db,
      repo: repo,
      retriever: retriever,
      embedder: embedder,
    );
  }

  static FakeLlmRunner _buildResponsesOnlyRunner(List<String> script) =>
      FakeLlmRunner(responses: script);

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

RecordingHandle _rec(String id, {int daysAgo = 0}) {
  final now = DateTime.utc(2026, 4, 19, 12);
  return RecordingHandle(
    id: id,
    audioFilePath: '/tmp/$id.wav',
    durationMs: 10_000,
    startedAt: now.subtract(Duration(days: daysAgo)),
  );
}

void main() {
  group('HybridRetriever.retrieve', () {
    test('empty query short-circuits to empty result', () async {
      final h = await _Harness.create(
        expanderScript: const <String>[],
        rerankerScript: const <String>[],
      );
      try {
        final r = await h.retriever.retrieve('');
        expect(r.isOk, isTrue);
        expect(r.okOrNull, isEmpty);
      } finally {
        await h.close();
      }
    });

    test('returns ranked chunks with fused + rrf + rerank scores',
        () async {
      final h = await _Harness.create(
        // Expander returns one paraphrase + no entities.
        expanderScript: const <String>[
          '{"paraphrases":["glowup pricing tiers"],"entities":[]}',
        ],
        // Reranker gives C1 the highest score.
        rerankerScript: const <String>[
          '{"C1": 9, "C2": 3, "C3": 1}',
        ],
        // Pin the clock to match _rec()'s reference so decay = 1.0.
        clock: () => DateTime.utc(2026, 4, 19, 12),
      );
      try {
        await h.repo.ingest(
          recording: _rec('a'),
          transcript: _tr('pricing for GlowUp finalized this quarter'),
          cleaned: _cl('pricing for GlowUp finalized this quarter'),
        );
        await h.repo.ingest(
          recording: _rec('b'),
          transcript: _tr('totally unrelated weather discussion'),
          cleaned: _cl('totally unrelated weather discussion'),
        );
        await h.repo.ingest(
          recording: _rec('c'),
          transcript: _tr('more unrelated content about birds'),
          cleaned: _cl('more unrelated content about birds'),
        );

        final r = await h.retriever.retrieve('GlowUp pricing');
        expect(r.isOk, isTrue, reason: '${r.errOrNull}');
        final ranked = r.okOrNull!;
        expect(ranked, isNotEmpty);
        // Top result should be chunk from log 'a' — rerank gave it 9/10.
        expect(ranked.first.chunk.logId.raw, 'a');
        // All scores populated.
        expect(ranked.first.rrfScore, greaterThan(0.0));
        expect(ranked.first.rerankScore, closeTo(0.9, 1e-9));
        expect(ranked.first.timeDecayFactor, closeTo(1.0, 1e-6));
        expect(
          ranked.first.fusedScore,
          closeTo(0.9 * 1.0, 1e-6),
        );
      } finally {
        await h.close();
      }
    });

    test('falls back to RRF score when rerank returns NaN', () async {
      final h = await _Harness.create(
        expanderScript: const <String>[
          '{"paraphrases":[],"entities":[]}',
        ],
        // Reranker double-fails; we expect NaN for every candidate
        // and fused = rrf * decay.
        rerankerScript: const <String>[
          'garbage',
          'still garbage',
        ],
      );
      try {
        await h.repo.ingest(
          recording: _rec('a'),
          transcript: _tr('pricing info'),
          cleaned: _cl('pricing info goes here for the search'),
        );
        final r = await h.retriever.retrieve('pricing');
        expect(r.isOk, isTrue);
        final ranked = r.okOrNull!;
        expect(ranked, isNotEmpty);
        expect(ranked.first.rerankScore.isNaN, isTrue);
        expect(
          ranked.first.fusedScore,
          closeTo(ranked.first.rrfScore * ranked.first.timeDecayFactor, 1e-9),
        );
      } finally {
        await h.close();
      }
    });

    test('time decay demotes older chunks', () async {
      DateTime clock() => DateTime.utc(2026, 4, 19, 12);
      final h = await _Harness.create(
        expanderScript: const <String>[
          '{"paraphrases":[],"entities":[]}',
        ],
        // Give both chunks the same rerank score so decay is the only
        // differentiator.
        rerankerScript: const <String>[
          '{"C1": 8, "C2": 8}',
        ],
        clock: clock,
      );
      try {
        await h.repo.ingest(
          recording: _rec('new', daysAgo: 1),
          transcript: _tr('recent pricing discussion'),
          cleaned: _cl('recent pricing discussion'),
        );
        await h.repo.ingest(
          recording: _rec('old', daysAgo: 90),
          transcript: _tr('old pricing discussion'),
          cleaned: _cl('old pricing discussion'),
        );

        final r = await h.retriever.retrieve('pricing');
        expect(r.isOk, isTrue);
        final ranked = r.okOrNull!;
        expect(ranked.length, greaterThanOrEqualTo(2));
        // Newer should come first under decay.
        expect(ranked.first.chunk.logId.raw, 'new');
        expect(
          ranked.first.timeDecayFactor,
          greaterThan(ranked.last.timeDecayFactor),
        );
      } finally {
        await h.close();
      }
    });

    test('respects the limit argument', () async {
      final h = await _Harness.create(
        expanderScript: const <String>[
          '{"paraphrases":[],"entities":[]}',
        ],
        rerankerScript: const <String>[
          '{"C1": 9, "C2": 8, "C3": 7, "C4": 6, "C5": 5}',
        ],
      );
      try {
        for (var i = 0; i < 5; i++) {
          await h.repo.ingest(
            recording: _rec('r$i', daysAgo: i),
            transcript: _tr('pricing chunk number $i'),
            cleaned: _cl('pricing chunk number $i with more text'),
          );
        }
        final r = await h.retriever.retrieve('pricing', limit: 2);
        expect(r.okOrNull, hasLength(2));
      } finally {
        await h.close();
      }
    });

    test('dateRange filter drops chunks outside the window', () async {
      DateTime clock() => DateTime.utc(2026, 4, 19, 12);
      final h = await _Harness.create(
        expanderScript: const <String>[
          '{"paraphrases":[],"entities":[]}',
        ],
        rerankerScript: const <String>[
          '{"C1": 7}',
        ],
        clock: clock,
      );
      try {
        // "new" is within range; "old" is outside.
        await h.repo.ingest(
          recording: _rec('new', daysAgo: 3),
          transcript: _tr('fresh pricing data'),
          cleaned: _cl('fresh pricing data here'),
        );
        await h.repo.ingest(
          recording: _rec('old', daysAgo: 300),
          transcript: _tr('ancient pricing data'),
          cleaned: _cl('ancient pricing data from long ago'),
        );
        final r = await h.retriever.retrieve(
          'pricing',
          dateRange: DateRange(
            from: clock().subtract(const Duration(days: 30)),
            to: clock(),
          ),
        );
        expect(r.isOk, isTrue);
        final ranked = r.okOrNull!;
        for (final hit in ranked) {
          expect(hit.chunk.logId.raw, 'new');
        }
      } finally {
        await h.close();
      }
    });

    test('skipRerank leaves rerankScore NaN and falls back to RRF',
        () async {
      final h = await _Harness.create(
        expanderScript: const <String>[
          '{"paraphrases":[],"entities":[]}',
        ],
        // No rerank calls expected.
        rerankerScript: const <String>[],
      );
      try {
        await h.repo.ingest(
          recording: _rec('a'),
          transcript: _tr('pricing notes'),
          cleaned: _cl('pricing notes for the launch'),
        );
        final r =
            await h.retriever.retrieve('pricing', skipRerank: true);
        expect(r.isOk, isTrue);
        final ranked = r.okOrNull!;
        expect(ranked, isNotEmpty);
        expect(ranked.first.rerankScore.isNaN, isTrue);
      } finally {
        await h.close();
      }
    });

    test('empty corpus returns empty result with no errors', () async {
      final h = await _Harness.create(
        expanderScript: const <String>[
          '{"paraphrases":[],"entities":[]}',
        ],
        rerankerScript: const <String>[],
      );
      try {
        final r = await h.retriever.retrieve('anything');
        expect(r.isOk, isTrue);
        expect(r.okOrNull, isEmpty);
      } finally {
        await h.close();
      }
    });

    test('intermediate debug scores (bm25Rank / vectorRank) are '
        'populated for the original query\'s lists', () async {
      final h = await _Harness.create(
        expanderScript: const <String>[
          '{"paraphrases":[],"entities":[]}',
        ],
        rerankerScript: const <String>[
          '{"C1": 5}',
        ],
      );
      try {
        await h.repo.ingest(
          recording: _rec('a'),
          transcript: _tr('pricing plans'),
          cleaned: _cl('pricing plans are ready'),
        );
        final r = await h.retriever.retrieve('pricing');
        final ranked = r.okOrNull!;
        final top = ranked.first;
        // At least one of bm25Rank or vectorRank should be non-null
        // (the chunk did appear in *some* backend list for the query).
        expect(top.bm25Rank != null || top.vectorRank != null, isTrue);
      } finally {
        await h.close();
      }
    });
  });
}
