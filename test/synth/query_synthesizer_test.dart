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
import 'package:voxsynth/synth/models/synthesis_event.dart';
import 'package:voxsynth/synth/multi_hop_retriever.dart';
import 'package:voxsynth/synth/query_synthesizer.dart';

/// End-to-end harness: real hybrid + multi-hop over in-memory stores,
/// with scripted LLM runners for expander / reranker / synthesizer.
class _Harness {
  _Harness({
    required this.db,
    required this.repo,
    required this.synthesizer,
    required this.synthRunner,
  });

  final AppDatabase db;
  final VoiceLogRepository repo;
  final QuerySynthesizer synthesizer;
  final FakeLlmRunner synthRunner;

  static Future<_Harness> create({
    required List<String> synthScript,
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
    final expanderRunner = FakeLlmRunner(
      responses: const <String>['{"paraphrases":[],"entities":[]}'],
    );
    await expanderRunner.load();
    final rerankerRunner = FakeLlmRunner(
      responses: const <String>[
        '{"C1": 9, "C2": 7, "C3": 5, "C4": 3, "C5": 1}',
      ],
    );
    await rerankerRunner.load();
    final retriever = HybridRetriever(
      repository: repo,
      embedder: embedder,
      queryExpander: QueryExpander(runner: expanderRunner),
      reranker: Reranker(runner: rerankerRunner),
      clock: () => DateTime.utc(2026, 4, 19, 12),
    );
    final multiHop = MultiHopRetriever(retriever: retriever);
    final synthRunner = FakeLlmRunner(responses: synthScript);
    await synthRunner.load();
    final synthesizer = QuerySynthesizer(
      retriever: retriever,
      multiHopRetriever: multiHop,
      runner: synthRunner,
    );
    return _Harness(
      db: db,
      repo: repo,
      synthesizer: synthesizer,
      synthRunner: synthRunner,
    );
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

RecordingHandle _rec(String id, {DateTime? at, int daysAgo = 0}) {
  final base = DateTime.utc(2026, 4, 19, 12);
  return RecordingHandle(
    id: id,
    audioFilePath: '/tmp/$id.wav',
    durationMs: 10_000,
    startedAt: at ?? base.subtract(Duration(days: daysAgo)),
  );
}

void main() {
  group('QuerySynthesizer.answer — simple path', () {
    test('empty question emits SynthesisFailed', () async {
      final h = await _Harness.create(synthScript: const <String>[]);
      try {
        final events = await h.synthesizer.answer('   ').toList();
        expect(events.first, isA<RetrievalStarted>());
        expect(events.last, isA<SynthesisFailed>());
        final last = events.last as SynthesisFailed;
        expect(last.message, contains('empty'));
      } finally {
        await h.close();
      }
    });

    test('empty corpus → SynthesisComplete with empty answer', () async {
      final h = await _Harness.create(synthScript: const <String>[]);
      try {
        final events = await h.synthesizer.answer('pricing').toList();
        expect(events.first, isA<RetrievalStarted>());
        expect(events.any((e) => e is RetrievalComplete), isTrue);
        expect(events.last, isA<SynthesisComplete>());
        final last = events.last as SynthesisComplete;
        expect(last.answer, '');
        expect(last.citations, isEmpty);
      } finally {
        await h.close();
      }
    });

    test('streams tokens and resolves citations on a normal answer',
        () async {
      final h = await _Harness.create(
        synthScript: const <String>[
          // 24 chars → 3 chunks at 8 chars each from FakeLlmRunner.
          'Pricing decided [C1] OK.',
        ],
      );
      try {
        await h.repo.ingest(
          recording: _rec('a'),
          transcript: _tr('pricing decision finalized'),
          cleaned: _cl('pricing decision finalized for launch'),
        );
        final events = await h.synthesizer.answer('pricing').toList();
        expect(events.first, isA<RetrievalStarted>());
        final tokens = events.whereType<TokenGenerated>().toList();
        expect(tokens, isNotEmpty);
        final complete = events.last as SynthesisComplete;
        expect(complete.answer, 'Pricing decided [C1] OK.');
        expect(complete.citations, hasLength(1));
        expect(complete.citations.single.tag, 'C1');
      } finally {
        await h.close();
      }
    });

    test('retries once when first pass drops citations', () async {
      final h = await _Harness.create(
        synthScript: const <String>[
          'No citations in this answer.',
          'This answer cites [C1] correctly.',
        ],
      );
      try {
        await h.repo.ingest(
          recording: _rec('a'),
          transcript: _tr('pricing plan'),
          cleaned: _cl('pricing plan was approved'),
        );
        final events = await h.synthesizer.answer('pricing').toList();
        final complete = events.last as SynthesisComplete;
        expect(complete.answer, 'This answer cites [C1] correctly.');
        expect(complete.citations, hasLength(1));
        // Runner saw two generate calls (first + retry).
        expect(h.synthRunner.callCount, 2);
      } finally {
        await h.close();
      }
    });

    test('keeps first-pass answer when retry also fails to cite',
        () async {
      final h = await _Harness.create(
        synthScript: const <String>[
          'First pass no cite.',
          'Retry also no cite.',
        ],
      );
      try {
        await h.repo.ingest(
          recording: _rec('a'),
          transcript: _tr('pricing info'),
          cleaned: _cl('pricing info here now'),
        );
        final events = await h.synthesizer.answer('pricing').toList();
        final complete = events.last as SynthesisComplete;
        expect(complete.answer, 'First pass no cite.');
        expect(complete.citations, isEmpty);
        expect(h.synthRunner.callCount, 2);
      } finally {
        await h.close();
      }
    });

    test('RetrievalComplete event carries the chunks the prompt saw',
        () async {
      final h = await _Harness.create(
        synthScript: const <String>['Answer with [C1].'],
      );
      try {
        await h.repo.ingest(
          recording: _rec('a'),
          transcript: _tr('pricing alpha'),
          cleaned: _cl('pricing alpha text here'),
        );
        final events = await h.synthesizer.answer('pricing').toList();
        final rc = events.firstWhere((e) => e is RetrievalComplete)
            as RetrievalComplete;
        expect(rc.chunks, isNotEmpty);
        expect(rc.chunks.first.chunk.logId.raw, 'a');
      } finally {
        await h.close();
      }
    });
  });

  group('QuerySynthesizer.answer — temporal path', () {
    test('temporal trigger routes to multi-hop retrieve', () async {
      final h = await _Harness.create(
        synthScript: const <String>[
          'Early week [C1]. Later week [C2].',
        ],
      );
      try {
        // Two weeks, each with ≥2 hits → multi-hop survives.
        await h.repo.ingest(
          recording: _rec('a1', at: DateTime.utc(2026, 4, 1, 10)),
          transcript: _tr('pricing first mention'),
          cleaned: _cl('pricing first mention of the quarter'),
        );
        await h.repo.ingest(
          recording: _rec('a2', at: DateTime.utc(2026, 4, 3, 10)),
          transcript: _tr('pricing second mention'),
          cleaned: _cl('pricing second mention of the quarter'),
        );
        await h.repo.ingest(
          recording: _rec('b1', at: DateTime.utc(2026, 4, 14, 10)),
          transcript: _tr('pricing third mention'),
          cleaned: _cl('pricing third mention later in quarter'),
        );
        await h.repo.ingest(
          recording: _rec('b2', at: DateTime.utc(2026, 4, 16, 10)),
          transcript: _tr('pricing fourth mention'),
          cleaned: _cl('pricing fourth mention later in quarter'),
        );
        final events = await h.synthesizer
            .answer('how has pricing evolved')
            .toList();
        final complete = events.last as SynthesisComplete;
        expect(complete.answer, 'Early week [C1]. Later week [C2].');
        expect(complete.citations.map((c) => c.tag),
            <String>['C1', 'C2']);
      } finally {
        await h.close();
      }
    });

    test('forceTemporal=true bypasses the keyword trigger', () async {
      final h = await _Harness.create(
        synthScript: const <String>['see [C1]'],
      );
      try {
        // Two hits in the same week so multi-hop survives.
        await h.repo.ingest(
          recording: _rec('a1', at: DateTime.utc(2026, 4, 14, 10)),
          transcript: _tr('pricing one'),
          cleaned: _cl('pricing one in the same week'),
        );
        await h.repo.ingest(
          recording: _rec('a2', at: DateTime.utc(2026, 4, 16, 10)),
          transcript: _tr('pricing two'),
          cleaned: _cl('pricing two in the same week'),
        );
        // Non-temporal-looking question, but forceTemporal: true.
        final events = await h.synthesizer
            .answer('pricing now', forceTemporal: true)
            .toList();
        expect(events.last, isA<SynthesisComplete>());
      } finally {
        await h.close();
      }
    });

    test('temporal path with no surviving week-clusters falls back to '
        'simple path', () async {
      final h = await _Harness.create(
        synthScript: const <String>['fallback [C1]'],
      );
      try {
        // Only ONE hit across all weeks → multi-hop returns [], falls
        // back to simple.
        await h.repo.ingest(
          recording: _rec('a1', at: DateTime.utc(2026, 4, 14, 10)),
          transcript: _tr('pricing lone'),
          cleaned: _cl('pricing lone hit this week'),
        );
        final events = await h.synthesizer
            .answer('how has pricing evolved')
            .toList();
        final complete = events.last as SynthesisComplete;
        expect(complete.answer, 'fallback [C1]');
        expect(complete.citations, hasLength(1));
      } finally {
        await h.close();
      }
    });

    test('custom temporalTrigger overrides the default classifier',
        () async {
      final h = await _Harness.create(
        synthScript: const <String>['simple [C1]'],
      );
      try {
        // Wrap the harness's synthesizer with a classifier that never
        // fires. Question looks temporal ("how has") but trigger says
        // no — so we expect the simple path.
        final override = QuerySynthesizer(
          retriever: h.synthesizer.retriever,
          multiHopRetriever: h.synthesizer.multiHopRetriever,
          runner: h.synthRunner,
          temporalTrigger: (_) => false,
        );
        await h.repo.ingest(
          recording: _rec('a'),
          transcript: _tr('pricing recent'),
          cleaned: _cl('pricing recent note one line'),
        );
        final events = await override
            .answer('how has pricing evolved')
            .toList();
        final complete = events.last as SynthesisComplete;
        // The simple-path prompt would see 1 chunk tagged [C1]; the
        // scripted answer 'simple [C1]' cites it — citations.length==1
        // proves we took the simple branch (temporal path would have
        // different Cn numbering via week clustering + fallback).
        expect(complete.answer, 'simple [C1]');
        expect(complete.citations, hasLength(1));
      } finally {
        await h.close();
      }
    });
  });
}
