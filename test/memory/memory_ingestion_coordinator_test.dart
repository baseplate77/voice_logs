import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:voxsynth/asr/models/transcript.dart';
import 'package:voxsynth/capture/models/speech_segment.dart';
import 'package:voxsynth/embed/embedder.dart';
import 'package:voxsynth/llm/llm_runner.dart';
import 'package:voxsynth/llm/models/cleaned_transcript.dart';
import 'package:voxsynth/memory/memory_consolidator.dart';
import 'package:voxsynth/memory/memory_extractor.dart';
import 'package:voxsynth/memory/memory_ingestion_coordinator.dart';
import 'package:voxsynth/memory/memory_repository.dart';
import 'package:voxsynth/memory/memory_vector_index.dart';
import 'package:voxsynth/memory/profile_builder.dart';
import 'package:voxsynth/store/app_database.dart';
import 'package:voxsynth/store/database_factory.dart';
import 'package:voxsynth/store/vector_index.dart';
import 'package:voxsynth/store/voice_log_repository.dart';

Future<AppDatabase> _openDb() async {
  final db = openInMemoryAppDatabase();
  await db.customSelect('SELECT 1').get();
  return db;
}

void main() {
  group('MemoryIngestionCoordinator', () {
    test('ingest → extract → consolidate → markStale end-to-end',
        () async {
      final db = await _openDb();
      final chunkEmbedder = FakeEmbedder();
      await chunkEmbedder.load();
      final memoryEmbedder = FakeEmbedder();
      await memoryEmbedder.load();

      final voiceLogRepo = VoiceLogRepository(
        db,
        embedder: chunkEmbedder,
        vectorIndex: InMemoryVectorIndex(),
        audioFileDeleter: (_) async {},
      );
      final memoryVectorIndex = InMemoryMemoryVectorIndex();
      final memoryRepo = MemoryRepository(
        db,
        vectorIndex: memoryVectorIndex,
        idSource: math.Random(99),
      );

      // Extractor returns one fact + one goal.
      const extractorPayload =
          '{"facts":[{"title":"works at acme",'
          '"content":"I work at Acme as a PM.",'
          '"confidence":0.9,"entity_names":[]}],'
          '"decisions":[],"episodes":[],'
          '"goals":[{"title":"ship v1","content":"Ship VoxSynth v1.",'
          '"state":"in_progress","due_at":"2026-06-01",'
          '"confidence":0.8,"entity_names":[]}]}';
      final extractorRunner = FakeLlmRunner(
        responses: const <String>[extractorPayload],
      );
      await extractorRunner.load();
      final extractor = MemoryExtractor(
        runner: extractorRunner,
        clock: () => DateTime.utc(2026, 4, 20),
      );

      // Judge isn't expected to fire on an empty store, but be
      // defensive.
      final judgeRunner = FakeLlmRunner(
        responses: const <String>['{"verdict":"unrelated"}'],
      );
      await judgeRunner.load();
      final consolidator = MemoryConsolidator(
        repository: memoryRepo,
        embedder: memoryEmbedder,
        vectorIndex: memoryVectorIndex,
        judgeRunner: judgeRunner,
        entityResolver: (_) async => const <String, int>{},
      );

      final profileRunner = FakeLlmRunner();
      await profileRunner.load();
      final profileBuilder = ProfileBuilder(
        repository: memoryRepo,
        runner: profileRunner,
      );

      final coordinator = MemoryIngestionCoordinator(
        voiceLogRepository: voiceLogRepo,
        extractor: extractor,
        consolidator: consolidator,
        profileBuilder: profileBuilder,
      );

      final rec = RecordingHandle(
        id: 'rec-ingest-1',
        audioFilePath: '/tmp/rec1.wav',
        durationMs: 1000,
        startedAt: DateTime.utc(2026, 4, 18, 9),
      );
      const cleaned = CleanedTranscript(
        text: 'I work at Acme as a PM. Ship VoxSynth v1.',
        chunks: <TopicChunk>[
          TopicChunk(
            text: 'I work at Acme as a PM.',
            startChar: 0,
            endChar: 23,
            topicHint: 'role',
          ),
          TopicChunk(
            text: 'Ship VoxSynth v1.',
            startChar: 24,
            endChar: 41,
            topicHint: 'goal',
          ),
        ],
        entities: <Entity>[],
        tags: <String>[],
      );

      final r = await coordinator.ingest(
        recording: rec,
        transcript: const Transcript(
          text: 'I work at Acme as a PM. Ship VoxSynth v1.',
          words: <Word>[],
          detectedLanguage: 'en',
        ),
        cleaned: cleaned,
      );
      expect(r.isOk, isTrue);
      final outcome = r.okOrNull!;
      expect(outcome.consolidation.created.length, 2);

      // Structural change → profile marked stale.
      final cache = await memoryRepo.loadProfileSummary();
      expect(cache.okOrNull!.isStale, isTrue);

      await db.close();
    });

    test('skips memory work when extractor errors', () async {
      final db = await _openDb();
      final chunkEmbedder = FakeEmbedder();
      await chunkEmbedder.load();
      final voiceLogRepo = VoiceLogRepository(
        db,
        embedder: chunkEmbedder,
        vectorIndex: InMemoryVectorIndex(),
        audioFileDeleter: (_) async {},
      );
      final memoryRepo = MemoryRepository(
        db,
        idSource: math.Random(1),
      );
      final extractorRunner = FakeLlmRunner(
        responses: const <String>['not-json'],
      );
      await extractorRunner.load();
      final extractor = MemoryExtractor(runner: extractorRunner);
      final judgeRunner = FakeLlmRunner();
      await judgeRunner.load();
      final profileRunner = FakeLlmRunner();
      await profileRunner.load();
      final consolidator = MemoryConsolidator(
        repository: memoryRepo,
        embedder: chunkEmbedder,
        vectorIndex: InMemoryMemoryVectorIndex(),
        judgeRunner: judgeRunner,
        entityResolver: (_) async => const <String, int>{},
      );
      final profileBuilder = ProfileBuilder(
        repository: memoryRepo,
        runner: profileRunner,
      );
      final coordinator = MemoryIngestionCoordinator(
        voiceLogRepository: voiceLogRepo,
        extractor: extractor,
        consolidator: consolidator,
        profileBuilder: profileBuilder,
      );
      final r = await coordinator.ingest(
        recording: RecordingHandle(
          id: 'rec-2',
          audioFilePath: '/tmp/rec2.wav',
          durationMs: 1000,
          startedAt: DateTime.utc(2026, 4, 18),
        ),
        transcript: const Transcript(
          text: 'hi',
          words: <Word>[],
          detectedLanguage: 'en',
        ),
        cleaned: const CleanedTranscript(
          text: 'hi',
          chunks: <TopicChunk>[
            TopicChunk(
              text: 'hi',
              startChar: 0,
              endChar: 2,
              topicHint: 'g',
            ),
          ],
          entities: <Entity>[],
          tags: <String>[],
        ),
      );
      expect(r.isOk, isTrue);
      expect(r.okOrNull!.consolidation.created, isEmpty);
      // Profile cache stale flag was never flipped (extraction bailed
      // before consolidation structural change).
      final cache = await memoryRepo.loadProfileSummary();
      expect(cache.okOrNull!.isStale, isFalse);
      await db.close();
    });
  });
}
