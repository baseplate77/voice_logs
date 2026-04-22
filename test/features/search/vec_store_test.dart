import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voxsynth/core/db/database.dart';
import 'package:voxsynth/core/db/repositories/voice_log_repository.dart';
import 'package:voxsynth/features/search/embedder.dart';
import 'package:voxsynth/features/search/segment_repository.dart';
import 'package:voxsynth/features/search/segmenter.dart';
import 'package:voxsynth/features/search/vec_store.dart';

Embedding _emb(Float32List v) => Embedding(vector: v, dim: v.length);

void main() {
  late VoxSynthDatabase db;
  late SegmentRepository segRepo;
  late VoiceLogRepository logRepo;

  setUp(() async {
    db = VoxSynthDatabase(NativeDatabase.memory());
    segRepo = SegmentRepository(db);
    logRepo = VoiceLogRepository(db);
    await logRepo.insertRecorded(
      id: 'log_a',
      createdAt: DateTime(2026, 4, 22),
      durationMs: 1000,
      audioPath: 'a.wav',
      rawTranscript: 'raw',
    );
  });

  tearDown(() => db.close());

  test('upsert persists segments + embeddings round-trip', () async {
    final v1 = Float32List(384);
    v1[0] = 1.0;
    final v2 = Float32List(384);
    v2[1] = 1.0;

    await segRepo.upsert(
      logId: 'log_a',
      segments: const [
        TextSegment(logId: 'log_a', index: 0, text: 'one'),
        TextSegment(logId: 'log_a', index: 1, text: 'two'),
      ],
      embeddings: [_emb(v1), _emb(v2)],
    );

    final stored = await segRepo.all();
    expect(stored, hasLength(2));
    expect(stored.first.text, 'one');
    expect(stored.first.embedding[0], 1.0);
    expect(stored.last.embedding[1], 1.0);
  });

  test('VecStore.search ranks by cosine similarity', () async {
    final v1 = Float32List(384);
    v1[0] = 1.0;
    final v2 = Float32List(384);
    v2[1] = 1.0;
    await segRepo.upsert(
      logId: 'log_a',
      segments: const [
        TextSegment(logId: 'log_a', index: 0, text: 'x-axis'),
        TextSegment(logId: 'log_a', index: 1, text: 'y-axis'),
      ],
      embeddings: [_emb(v1), _emb(v2)],
    );

    final store = VecStore(segRepo);
    await store.load();

    final q = Float32List(384);
    q[0] = 0.9;
    q[1] = 0.436;
    final hits = store.search(q, k: 2);
    expect(hits.first.text, 'x-axis');
    expect(hits.first.score, closeTo(0.9, 1e-4));
  });
}
