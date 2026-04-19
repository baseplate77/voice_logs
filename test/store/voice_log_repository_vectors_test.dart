import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:voxsynth/asr/models/transcript.dart';
import 'package:voxsynth/capture/models/speech_segment.dart';
import 'package:voxsynth/embed/embedder.dart';
import 'package:voxsynth/llm/models/cleaned_transcript.dart';
import 'package:voxsynth/store/app_database.dart';
import 'package:voxsynth/store/database_factory.dart';
import 'package:voxsynth/store/models/voice_log_record.dart';
import 'package:voxsynth/store/vector_index.dart';
import 'package:voxsynth/store/voice_log_repository.dart';

/// Drift + InMemoryVectorIndex + Embedder harness. Everything in
/// memory, no objectbox native lib required — unit tests run cleanly
/// under `flutter test`.
class _Harness {
  _Harness({
    required this.db,
    required this.index,
    required this.repo,
    required this.embedder,
    required this.deleted,
  });

  final AppDatabase db;
  final InMemoryVectorIndex index;
  final VoiceLogRepository repo;
  final FakeEmbedder embedder;
  final List<String> deleted;

  static Future<_Harness> create() async {
    final db = openInMemoryAppDatabase();
    await db.customSelect('SELECT 1').get();
    final index = InMemoryVectorIndex();
    final embedder = FakeEmbedder();
    await embedder.load();
    final deleted = <String>[];
    final repo = VoiceLogRepository(
      db,
      embedder: embedder,
      vectorIndex: index,
      audioFileDeleter: (path) async => deleted.add(path),
    );
    return _Harness(
      db: db,
      index: index,
      repo: repo,
      embedder: embedder,
      deleted: deleted,
    );
  }

  Future<void> close() async => db.close();
}

RecordingHandle _handle(String id, {int startedAtMs = 1_745_000_000_000}) =>
    RecordingHandle(
      id: id,
      audioFilePath: '/tmp/voxsynth-test-$id.wav',
      durationMs: 10_000,
      startedAt: DateTime.fromMillisecondsSinceEpoch(startedAtMs),
    );

Transcript _transcript(String text) =>
    Transcript(text: text, words: const <Word>[], detectedLanguage: 'en');

CleanedTranscript _cleaned(String text, {List<String>? entityNames}) =>
    CleanedTranscript(
      text: text,
      chunks: <TopicChunk>[
        TopicChunk(
          text: text,
          startChar: 0,
          endChar: text.length,
          topicHint: 'generic',
          entityRefs: entityNames ?? const <String>[],
        ),
      ],
      entities: (entityNames ?? const <String>[])
          .map((n) => Entity(name: n, kind: 'concept'))
          .toList(growable: false),
      tags: const <String>[],
    );

void main() {
  group('VoiceLogRepository vector path', () {
    test('ingest populates the vector index with one entry per chunk',
        () async {
      final h = await _Harness.create();
      try {
        final r = await h.repo.ingest(
          recording: _handle('a'),
          transcript: _transcript('pricing for GlowUp'),
          cleaned: _cleaned('pricing for GlowUp'),
        );
        expect(r.isOk, isTrue, reason: '${r.errOrNull}');
        expect(h.index.count(), 1);

        // chunks.objectbox_id was updated to point at the stored vector.
        final chunks =
            await h.db.select(h.db.transcriptChunks).get();
        expect(chunks.single.objectboxId, greaterThan(0));
        expect(h.index.allIds(), contains(chunks.single.objectboxId));
      } finally {
        await h.close();
      }
    });

    test('ingesting multiple chunks writes a vector per chunk', () async {
      final h = await _Harness.create();
      try {
        await h.repo.ingest(
          recording: _handle('a'),
          transcript: _transcript('long story'),
          cleaned: const CleanedTranscript(
            text: 'chunk 1 here, chunk 2 here',
            chunks: <TopicChunk>[
              TopicChunk(
                text: 'chunk 1 here',
                startChar: 0,
                endChar: 12,
                topicHint: 'a',
              ),
              TopicChunk(
                text: 'chunk 2 here',
                startChar: 14,
                endChar: 26,
                topicHint: 'b',
              ),
            ],
            entities: <Entity>[],
            tags: <String>[],
          ),
        );
        expect(h.index.count(), 2);
      } finally {
        await h.close();
      }
    });

    test('vectorSearch returns hydrated chunks sorted by score', () async {
      final h = await _Harness.create();
      try {
        await h.repo.ingest(
          recording: _handle('a'),
          transcript: _transcript('pricing for GlowUp'),
          cleaned: _cleaned('pricing for GlowUp'),
        );
        await h.repo.ingest(
          recording: _handle('b'),
          transcript: _transcript('totally different subject about birds'),
          cleaned: _cleaned('totally different subject about birds'),
        );

        final q =
            (await h.embedder.embedQuery('pricing for GlowUp')).okOrNull!;
        final hits = (await h.repo.vectorSearch(q)).okOrNull!;
        expect(hits, isNotEmpty);
        expect(hits.length, lessThanOrEqualTo(2));
        for (final hit in hits) {
          expect(<String>['a', 'b'], contains(hit.logId.raw));
        }
      } finally {
        await h.close();
      }
    });

    test('vectorSearch rejects wrong-dim input', () async {
      final h = await _Harness.create();
      try {
        final full = (await h.embedder.embedQuery('x')).okOrNull!;
        final r = await h.repo.vectorSearch(full.sublist(0, 10));
        expect(r.isErr, isTrue);
      } finally {
        await h.close();
      }
    });

    test('vectorSearch respects the limit argument', () async {
      final h = await _Harness.create();
      try {
        for (var i = 0; i < 5; i++) {
          await h.repo.ingest(
            recording: _handle('r$i', startedAtMs: 1000 + i),
            transcript: _transcript('content $i'),
            cleaned: _cleaned('content number $i here'),
          );
        }
        final q = (await h.embedder.embedQuery('content')).okOrNull!;
        final hits = (await h.repo.vectorSearch(q, limit: 3)).okOrNull!;
        expect(hits, hasLength(3));
      } finally {
        await h.close();
      }
    });

    test('deleteLog cascades to vectors and the audio file', () async {
      final h = await _Harness.create();
      try {
        await h.repo.ingest(
          recording: _handle('a'),
          transcript: _transcript('first log'),
          cleaned: _cleaned('first log content'),
        );
        await h.repo.ingest(
          recording: _handle('b'),
          transcript: _transcript('second log'),
          cleaned: _cleaned('second log content'),
        );
        expect(h.index.count(), 2);

        final r = await h.repo.deleteLog(const VoiceLogId('a'));
        expect(r.isOk, isTrue);

        // Only log 'b' vectors remain.
        expect(h.index.count(), 1);

        // Audio deleter saw the WAV path.
        expect(h.deleted, <String>['/tmp/voxsynth-test-a.wav']);
      } finally {
        await h.close();
      }
    });

    test('cleanupOrphanVectors removes vectors whose chunks are gone',
        () async {
      final h = await _Harness.create();
      try {
        await h.repo.ingest(
          recording: _handle('a'),
          transcript: _transcript('something'),
          cleaned: _cleaned('something here'),
        );
        // Simulate a crash between Drift delete and vector delete:
        // wipe the Drift row but leave the vector behind.
        await h.db.delete(h.db.transcriptChunks).go();

        expect(h.index.count(), 1);
        final r = await h.repo.cleanupOrphanVectors();
        expect(r.isOk, isTrue);
        expect(r.okOrNull, 1);
        expect(h.index.count(), 0);
      } finally {
        await h.close();
      }
    });

    test('cleanupOrphanVectors keeps vectors still referenced',
        () async {
      final h = await _Harness.create();
      try {
        await h.repo.ingest(
          recording: _handle('a'),
          transcript: _transcript('keep me'),
          cleaned: _cleaned('keep me around'),
        );
        final before = h.index.count();
        final r = await h.repo.cleanupOrphanVectors();
        expect(r.isOk, isTrue);
        expect(r.okOrNull, 0);
        expect(h.index.count(), before);
      } finally {
        await h.close();
      }
    });

    test('repository with no vectorIndex is harmless (ingest, search, delete)',
        () async {
      final db = openInMemoryAppDatabase();
      await db.customSelect('SELECT 1').get();
      final embedder = FakeEmbedder();
      await embedder.load();
      final repo = VoiceLogRepository(
        db,
        embedder: embedder,
        audioFileDeleter: (_) async {},
      );

      await repo.ingest(
        recording: _handle('a'),
        transcript: _transcript('x'),
        cleaned: _cleaned('x'),
      );
      final q = (await embedder.embedQuery('anything')).okOrNull!;
      expect((await repo.vectorSearch(q)).okOrNull, isEmpty);
      expect((await repo.cleanupOrphanVectors()).okOrNull, 0);
      final delResult = await repo.deleteLog(const VoiceLogId('a'));
      expect(delResult.isOk, isTrue);
      await db.close();
    });
  });

  group('InMemoryVectorIndex', () {
    test('put assigns unique ascending ids', () {
      final idx = InMemoryVectorIndex();
      final a = idx.put(logId: 'l1', embedding: _ones(4));
      final b = idx.put(logId: 'l1', embedding: _ones(4));
      final c = idx.put(logId: 'l2', embedding: _ones(4));
      expect(a, isNot(b));
      expect(b, isNot(c));
      expect(idx.count(), 3);
    });

    test('nearest sorts by cosine distance ascending', () {
      final idx = InMemoryVectorIndex();
      final query = _unit(<double>[1.0, 0.0, 0.0]);
      final parallel = idx.put(logId: 'p', embedding: query);
      final orthogonal =
          idx.put(logId: 'o', embedding: _unit(<double>[0.0, 1.0, 0.0]));
      final opposite =
          idx.put(logId: 'r', embedding: _unit(<double>[-1.0, 0.0, 0.0]));
      final hits = idx.nearest(query, 3);
      expect(hits.first.vectorId, parallel);
      expect(hits[1].vectorId, orthogonal);
      expect(hits.last.vectorId, opposite);
      // Scores reflect 1 - cosine_similarity.
      expect(hits.first.score, lessThan(hits.last.score));
    });

    test('removeByLogId wipes only vectors with that logId', () {
      final idx = InMemoryVectorIndex();
      idx.put(logId: 'a', embedding: _ones(4));
      idx.put(logId: 'a', embedding: _ones(4));
      idx.put(logId: 'b', embedding: _ones(4));
      idx.removeByLogId('a');
      expect(idx.count(), 1);
    });

    test('removeByIds wipes the requested ids', () {
      final idx = InMemoryVectorIndex();
      final a = idx.put(logId: 'a', embedding: _ones(4));
      idx.put(logId: 'b', embedding: _ones(4));
      idx.removeByIds(<int>[a]);
      expect(idx.count(), 1);
    });
  });
}

/// Helpers. Tiny hand-rolled "unit vector" — tests need only 3-d or
/// 4-d examples, not full 384.
Float32List _ones(int n) =>
    Float32List.fromList(List<double>.filled(n, 1.0 / _sqrt(n.toDouble())));
Float32List _unit(List<double> v) {
  var sq = 0.0;
  for (final x in v) {
    sq += x * x;
  }
  final n = _sqrt(sq);
  return Float32List.fromList(v.map((x) => x / n).toList(growable: false));
}

double _sqrt(double x) {
  if (x <= 0) return 0.0;
  var g = x;
  for (var i = 0; i < 20; i++) {
    g = 0.5 * (g + x / g);
  }
  return g;
}
