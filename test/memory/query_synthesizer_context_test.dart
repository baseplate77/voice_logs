import 'package:flutter_test/flutter_test.dart';
import 'package:voxsynth/asr/models/transcript.dart';
import 'package:voxsynth/capture/models/speech_segment.dart';
import 'package:voxsynth/embed/embedder.dart';
import 'package:voxsynth/llm/llm_runner.dart';
import 'package:voxsynth/llm/models/cleaned_transcript.dart';
import 'package:voxsynth/memory/models/memory.dart';
import 'package:voxsynth/memory/models/profile_summary.dart';
import 'package:voxsynth/memory/models/ranked_memory.dart';
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

/// Capturing runner: records prompts in addition to returning scripted
/// responses. Used to assert the profile + memories landed in the
/// prompt body.
class _CapturingRunner extends FakeLlmRunner {
  _CapturingRunner({required super.responses});

  final List<String> prompts = <String>[];

  @override
  Stream<String> generate(String prompt, {double? temperatureOverride}) {
    prompts.add(prompt);
    return super
        .generate(prompt, temperatureOverride: temperatureOverride);
  }
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

RecordingHandle _rec() => RecordingHandle(
      id: 'r1',
      audioFilePath: '/tmp/r1.wav',
      durationMs: 1000,
      startedAt: DateTime.utc(2026, 4, 18, 9),
    );

void main() {
  group('QuerySynthesizer.answerWithContext', () {
    late AppDatabase db;
    late VoiceLogRepository repo;
    late _CapturingRunner synthRunner;
    late QuerySynthesizer synth;

    setUp(() async {
      db = openInMemoryAppDatabase();
      await db.customSelect('SELECT 1').get();
      final embedder = FakeEmbedder();
      await embedder.load();
      final vectorIndex = InMemoryVectorIndex();
      repo = VoiceLogRepository(
        db,
        embedder: embedder,
        vectorIndex: vectorIndex,
        audioFileDeleter: (_) async {},
      );
      await repo.ingest(
        recording: _rec(),
        transcript: _tr('I finalized the pricing decision today.'),
        cleaned: _cl('I finalized the pricing decision today.'),
      );
      final expander = FakeLlmRunner(
        responses: const <String>['{"paraphrases":[],"entities":[]}'],
      );
      await expander.load();
      final rerankerRunner = FakeLlmRunner(
        responses: const <String>['{"C1": 9}'],
      );
      await rerankerRunner.load();
      final retriever = HybridRetriever(
        repository: repo,
        embedder: embedder,
        queryExpander: QueryExpander(runner: expander),
        reranker: Reranker(runner: rerankerRunner),
        clock: () => DateTime.utc(2026, 4, 19, 12),
      );
      final multiHop = MultiHopRetriever(retriever: retriever);
      synthRunner = _CapturingRunner(
        responses: const <String>[
          'The pricing decision happened [C1] and is backed by [M1].',
        ],
      );
      await synthRunner.load();
      synth = QuerySynthesizer(
        retriever: retriever,
        multiHopRetriever: multiHop,
        runner: synthRunner,
      );
    });

    tearDown(() => db.close());

    test('answer() (no context) still works — prompt carries chunks only',
        () async {
      final events = await synth.answer('what happened').toList();
      final completed =
          events.whereType<SynthesisComplete>().single;
      expect(completed.citations.length, 1);
      expect(completed.citations.first.tag, 'C1');
      // The no-context prompt must not reference profile/memories.
      expect(synthRunner.prompts.single, isNot(contains('About the user')));
      expect(synthRunner.prompts.single, isNot(contains('[M1]')));
    });

    test('answerWithContext threads profile + memories into the prompt',
        () async {
      final profile = ProfileSummary(
        summary: 'Senior PM at Acme, shipping VoxSynth v1.',
        updatedAt: DateTime.utc(2026, 4, 20),
        sourceMemoryIds: const <MemoryId>[],
        isStale: false,
      );
      final memory = FactMemory(
        id: const MemoryId('mem-1'),
        title: 'works at acme',
        content: 'I work at Acme as a senior PM.',
        status: MemoryStatus.active,
        confidence: 0.9,
        createdAt: DateTime.utc(2026, 4, 18),
        updatedAt: DateTime.utc(2026, 4, 18),
      );
      final ranked = RankedMemory(
        memory: memory,
        fusedScore: 1.0,
        rrfScore: 1.0,
        timeDecayFactor: 1.0,
      );

      final events = await synth
          .answerWithContext(
            'where do I work',
            profile: profile,
            memories: <RankedMemory>[ranked],
          )
          .toList();
      final completed = events.whereType<SynthesisComplete>().single;

      final prompt = synthRunner.prompts.single;
      expect(prompt, contains('About the user'));
      expect(prompt, contains('Senior PM at Acme'));
      expect(prompt, contains('Relevant memories'));
      expect(prompt, contains('[M1]'));
      expect(prompt, contains('I work at Acme'));

      // Citations resolve unified namespace — both [C1] and [M1].
      final tags =
          completed.citations.map((c) => c.tag).toList(growable: false);
      expect(tags, containsAll(<String>['C1', 'M1']));
      final memCite =
          completed.citations.firstWhere((c) => c.tag == 'M1');
      expect(memCite.memoryId, 'mem-1');
      expect(memCite.sourceKind, CitationSourceKind.memory);
    });
  });
}
