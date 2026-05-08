import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voxsynth/core/db/database.dart';
import 'package:voxsynth/core/db/repositories/canonical_entity_repository.dart';
import 'package:voxsynth/core/db/repositories/entity_mention_repository.dart';
import 'package:voxsynth/core/db/repositories/memory_repository.dart';
import 'package:voxsynth/core/db/repositories/voice_log_repository.dart';
import 'package:voxsynth/core/result.dart';
import 'package:voxsynth/core/worker/job_handler.dart';
import 'package:voxsynth/features/memory/memory_extractor.dart';
import 'package:voxsynth/features/memory/memory_job.dart';
import 'package:voxsynth/features/memory/memory_types.dart';
import 'package:voxsynth/features/refine/llm_runner.dart';
import 'package:voxsynth/features/refine/offset_recovery.dart';
import 'package:voxsynth/features/search/embedder.dart';

class _FakeRunner implements LlmRunner {
  @override
  Future<void> dispose() async {}

  @override
  Future<Result<String, LlmError>> generate(
    String prompt, {
    double temperature = 0.3,
  }) async => const Ok('''
    {
      "memories": [
        {
          "type": "relationship",
          "text": "Shivani is the user's coworker.",
          "evidence": "Shivani is my coworker",
          "confidence": 0.94,
          "sensitivity": "normal"
        }
      ]
    }
    ''');

  @override
  Future<Result<void, LlmError>> load() async => const Ok(null);

  @override
  Future<void> unload() async {}
}

class _FakeEmbedder implements Embedder {
  @override
  Future<void> dispose() async {}

  @override
  Future<Result<List<Embedding>, EmbedError>> embedPassages(
    List<String> texts, {
    int? batchSize,
  }) async => Ok(
    texts
        .map((_) => Embedding(vector: Float32List.fromList([1, 0]), dim: 2))
        .toList(),
  );

  @override
  Future<Result<Embedding, EmbedError>> embedQuery(String text) async =>
      Ok(Embedding(vector: Float32List.fromList([1, 0]), dim: 2));

  @override
  Future<Result<void, EmbedError>> load() async => const Ok(null);
}

void main() {
  test(
    'MemoryJobHandler persists extracted memories and entity links',
    () async {
      final db = VoxSynthDatabase(NativeDatabase.memory());
      addTearDown(db.close);

      final logs = VoiceLogRepository(db);
      final mentions = EntityMentionRepository(db);
      final memories = MemoryRepository(db);
      final canon = CanonicalEntityRepository(db);

      await logs.insertRecorded(
        id: 'log_1',
        createdAt: DateTime(2026, 5, 7),
        durationMs: 1000,
        audioPath: 'audio/log_1.wav',
        rawTranscript: 'Shivani is my coworker.',
      );
      await logs.markRefined(
        id: 'log_1',
        cleanedText: 'Shivani is my coworker.',
      );
      await mentions.replaceForLog(
        logId: 'log_1',
        mentions: const [
          LocatedMention(
            text: 'Shivani',
            type: 'PERSON',
            charStart: 0,
            charEnd: 7,
          ),
        ],
      );
      final entityRes = await canon.create(
        displayName: 'Shivani',
        type: 'PERSON',
        embedding: Float32List.fromList([1, 0]),
      );
      final entityId = (entityRes as Ok<String, CanonicalEntityError>).value;
      await (db.update(db.entityMentions)
            ..where((t) => t.logId.equals('log_1')))
          .write(EntityMentionsCompanion(canonicalEntityId: Value(entityId)));

      final handler = MemoryJobHandler(
        voiceLogs: logs,
        mentions: mentions,
        extractor: MemoryExtractor(runner: _FakeRunner()),
        embedder: _FakeEmbedder(),
        memories: memories,
      );

      final res = await handler.handle(
        const JobContext(jobId: 'job_1', logId: 'log_1', attempts: 0),
      );

      expect(res.isOk, isTrue);
      final all = await memories.all();
      expect(all.single.text, "Shivani is the user's coworker.");
      expect(all.single.status, MemoryStatus.active);

      final linkCount = await db
          .customSelect('SELECT COUNT(*) AS c FROM memory_entity_links')
          .getSingle();
      expect(linkCount.read<int>('c'), 1);
    },
  );
}
