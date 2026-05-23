import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voxsynth/core/db/database.dart';
import 'package:voxsynth/core/db/repositories/canonical_entity_repository.dart';
import 'package:voxsynth/core/db/repositories/memory_repository.dart';
import 'package:voxsynth/core/db/repositories/voice_log_repository.dart';
import 'package:voxsynth/core/result.dart';
import 'package:voxsynth/features/memory/memory_retriever.dart';
import 'package:voxsynth/features/memory/memory_types.dart';
import 'package:voxsynth/features/search/embedder.dart';

class _FakeEmbedder implements Embedder {
  _FakeEmbedder(this.queryVector);

  final Float32List queryVector;

  @override
  Future<void> dispose() async {}

  @override
  Future<Result<List<Embedding>, EmbedError>> embedPassages(
    List<String> texts, {
    int? batchSize,
  }) async => Ok(
    texts
        .map((_) => Embedding(vector: queryVector, dim: queryVector.length))
        .toList(),
  );

  @override
  Future<Result<Embedding, EmbedError>> embedQuery(String text) async =>
      Ok(Embedding(vector: queryVector, dim: queryVector.length));

  @override
  Future<Result<void, EmbedError>> load() async => const Ok(null);
}

void main() {
  late VoxSynthDatabase db;
  late VoiceLogRepository logs;
  late MemoryRepository memories;

  setUp(() async {
    db = VoxSynthDatabase(NativeDatabase.memory());
    logs = VoiceLogRepository(db);
    memories = MemoryRepository(db);
    await logs.insertRecorded(
      id: 'log_1',
      createdAt: DateTime(2026, 5, 7),
      durationMs: 1000,
      audioPath: 'audio/log_1.wav',
      rawTranscript: 'I prefer privacy preserving local apps.',
    );
  });

  tearDown(() => db.close());

  test('returns FTS and vector memory hits', () async {
    await memories.createOrUpdate(
      candidate: const MemoryCandidate(
        type: MemoryType.preference,
        text: 'User prefers privacy preserving local apps.',
        evidence: 'I prefer privacy preserving local apps',
        confidence: 0.95,
        sensitivity: MemorySensitivity.normal,
        startChar: 0,
        endChar: 38,
      ),
      sourceLogId: 'log_1',
      embedding: Float32List.fromList([1, 0]),
    );

    final retriever = MemoryRetriever(
      db: db,
      repository: memories,
      embedder: _FakeEmbedder(Float32List.fromList([1, 0])),
    );

    final res = await retriever.search('privacy');
    expect(res, isA<Ok<List<MemoryHit>, MemoryRetrieverError>>());
    final hits = (res as Ok<List<MemoryHit>, MemoryRetrieverError>).value;
    expect(hits, hasLength(1));
    expect(hits.first.memory.text, contains('privacy'));
    expect(hits.first.matchedVia, contains(MemoryMatchSource.fts));
    expect(hits.first.matchedVia, contains(MemoryMatchSource.vector));
  });

  test('returns entity-linked memory hits', () async {
    final canon = CanonicalEntityRepository(db);
    final entityRes = await canon.create(
      displayName: 'Shivani',
      type: 'PERSON',
      embedding: Float32List.fromList([1, 0]),
    );
    final entityId = (entityRes as Ok<String, CanonicalEntityError>).value;

    final memoryRes = await memories.createOrUpdate(
      candidate: const MemoryCandidate(
        type: MemoryType.relationship,
        text: 'Shivani is the user\'s coworker.',
        evidence: 'Shivani is my coworker',
        confidence: 0.95,
        sensitivity: MemorySensitivity.normal,
        startChar: 0,
        endChar: 22,
      ),
      sourceLogId: 'log_1',
      embedding: Float32List.fromList([0, 1]),
      canonicalEntityIds: [entityId],
    );
    expect(memoryRes.isOk, isTrue);

    final retriever = MemoryRetriever(
      db: db,
      repository: memories,
      embedder: _FakeEmbedder(Float32List.fromList([-1, 0])),
    );

    final res = await retriever.search('Shivani');
    final hits = (res as Ok<List<MemoryHit>, MemoryRetrieverError>).value;
    expect(
      hits.map((h) => h.memory.text),
      contains('Shivani is the user\'s coworker.'),
    );
    expect(hits.first.matchedVia, contains(MemoryMatchSource.entity));
  });

  test('natural-language memory query uses type and yesterday date', () async {
    final memoryRes = await memories.createOrUpdate(
      candidate: const MemoryCandidate(
        type: MemoryType.idea,
        text: 'Build offline summarization for meeting notes.',
        evidence: 'Build offline summarization',
        confidence: 0.95,
        sensitivity: MemorySensitivity.normal,
        startChar: 0,
        endChar: 27,
      ),
      sourceLogId: 'log_1',
      embedding: Float32List.fromList([0, 1]),
    );
    final memory =
        (memoryRes as Ok<MemoryItemView, MemoryRepositoryError>).value;
    final yesterday = DateTime(2026, 5, 22, 9).millisecondsSinceEpoch;
    await db.customStatement(
      'UPDATE memory_items SET last_seen_at = ?, updated_at = ? WHERE id = ?',
      [yesterday, yesterday, memory.id],
    );

    final retriever = MemoryRetriever(
      db: db,
      repository: memories,
      embedder: _FakeEmbedder(Float32List.fromList([-1, 0])),
      now: () => DateTime(2026, 5, 23, 12),
    );

    final res = await retriever.search('what idea did I get yesterday');
    final hits = (res as Ok<List<MemoryHit>, MemoryRetrieverError>).value;
    expect(hits.map((h) => h.memory.id), contains(memory.id));
    expect(hits.first.matchedVia, contains(MemoryMatchSource.type));
    expect(hits.first.matchedVia, contains(MemoryMatchSource.date));
  });
}
