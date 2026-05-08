import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voxsynth/core/db/database.dart';
import 'package:voxsynth/core/db/repositories/voice_log_repository.dart';
import 'package:voxsynth/core/result.dart';
import 'package:voxsynth/features/search/embedder.dart';
import 'package:voxsynth/features/search/hybrid_retriever.dart';
import 'package:voxsynth/features/search/segment_repository.dart';
import 'package:voxsynth/features/search/vec_store.dart';

class _FailingEmbedder implements Embedder {
  @override
  Future<void> dispose() async {}

  @override
  Future<Result<List<Embedding>, EmbedError>> embedPassages(
    List<String> texts, {
    int? batchSize,
  }) async => const Err(EmbedRuntimeError(message: 'missing e5'));

  @override
  Future<Result<Embedding, EmbedError>> embedQuery(String text) async =>
      const Err(EmbedRuntimeError(message: 'missing e5'));

  @override
  Future<Result<void, EmbedError>> load() async =>
      const Err(EmbedRuntimeError(message: 'missing e5'));
}

void main() {
  test('falls back to FTS results when query embedding fails', () async {
    final db = VoxSynthDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final repo = VoiceLogRepository(db);
    await repo.insertRecorded(
      id: 'log_1',
      createdAt: DateTime(2026, 5, 7),
      durationMs: 1000,
      audioPath: 'audio/log_1.wav',
      rawTranscript: 'hello from the raw transcript',
    );

    final retriever = HybridRetriever(
      db: db,
      embedder: _FailingEmbedder(),
      vecStore: VecStore(SegmentRepository(db)),
    );

    final res = await retriever.search('hello');
    expect(res, isA<Ok<List<SearchHit>, RetrieverError>>());
    final hits = (res as Ok<List<SearchHit>, RetrieverError>).value;
    expect(hits.map((h) => h.logId), contains('log_1'));
    expect(hits.single.matchedVia, contains(MatchSource.fts));
  });
}
