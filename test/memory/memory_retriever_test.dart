import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:voxsynth/core/errors.dart';
import 'package:voxsynth/core/result.dart';
import 'package:voxsynth/embed/embedder.dart';
import 'package:voxsynth/memory/memory_repository.dart';
import 'package:voxsynth/memory/memory_retriever.dart';
import 'package:voxsynth/memory/memory_vector_index.dart';
import 'package:voxsynth/memory/models/memory.dart';
import 'package:voxsynth/store/app_database.dart';
import 'package:voxsynth/store/database_factory.dart';

Future<AppDatabase> _openDb() async {
  final db = openInMemoryAppDatabase();
  await db.customSelect('SELECT 1').get();
  return db;
}

/// Returns vectors seeded per-text so the retriever can distinguish
/// candidates at query time.
class _PerTextEmbedder implements Embedder {
  @override
  int get embeddingDim => 384;

  @override
  Future<Result<void, AppError>> load() async =>
      const Ok<void, AppError>(null);

  @override
  Future<Result<List<Float32List>, AppError>> embedPassages(
    List<String> texts,
  ) async =>
      Ok<List<Float32List>, AppError>(
        texts.map(_forText).toList(growable: false),
      );

  @override
  Future<Result<Float32List, AppError>> embedQuery(String text) async =>
      Ok<Float32List, AppError>(_forText(text));

  @override
  Future<void> dispose() async {}

  Float32List _forText(String t) {
    final out = Float32List(384);
    var h = 2166136261;
    for (var i = 0; i < t.length; i++) {
      h ^= t.codeUnitAt(i);
      h = (h * 16777619) & 0xFFFFFFFF;
    }
    var sq = 0.0;
    for (var i = 0; i < out.length; i++) {
      h = (h * 16777619 + 17) & 0xFFFFFFFF;
      final v = ((h & 0xFFFF) / 0xFFFF) * 2.0 - 1.0;
      out[i] = v;
      sq += v * v;
    }
    final inv = sq == 0 ? 1.0 : 1.0 / math.sqrt(sq);
    for (var i = 0; i < out.length; i++) {
      out[i] *= inv;
    }
    return out;
  }
}

void main() {
  group('MemoryRetriever', () {
    late AppDatabase db;
    late MemoryRepository repo;
    late InMemoryMemoryVectorIndex index;
    late Embedder embedder;

    setUp(() async {
      db = await _openDb();
      index = InMemoryMemoryVectorIndex();
      repo = MemoryRepository(
        db,
        vectorIndex: index,
        idSource: math.Random(3),
      );
      embedder = _PerTextEmbedder();
      await embedder.load();
    });

    tearDown(() => db.close());

    Future<MemoryId> seed({
      required String title,
      required String content,
      DateTime? createdAt,
      MemoryStatus status = MemoryStatus.active,
    }) async {
      final id = repo.id$$noop() ?? repo.newId();
      final ts = createdAt ?? DateTime.utc(2026, 4, 18);
      final embR = await embedder.embedPassages(<String>['$title\n\n$content']);
      await repo.save(
        FactMemory(
          id: id,
          title: title,
          content: content,
          status: status,
          confidence: 0.9,
          createdAt: ts,
          updatedAt: ts,
        ),
        embedding: embR.okOrNull!.first,
      );
      return id;
    }

    test('retrieves memories matching a query via FTS + vector', () async {
      await seed(
        title: 'works at acme',
        content: 'I work at Acme as a senior product manager.',
      );
      await seed(
        title: 'runs weekend',
        content: 'I run a half marathon every weekend.',
      );
      final retriever = MemoryRetriever(
        db: db,
        repository: repo,
        embedder: embedder,
        vectorIndex: index,
      );
      final r = await retriever.retrieve('where do I work');
      expect(r.isOk, isTrue);
      final ranked = r.okOrNull!;
      expect(ranked, isNotEmpty);
      expect(ranked.first.memory.title, 'works at acme');
    });

    test('empty query returns empty list', () async {
      final retriever = MemoryRetriever(
        db: db,
        repository: repo,
        embedder: embedder,
        vectorIndex: index,
      );
      final r = await retriever.retrieve('   ');
      expect(r.okOrNull, isEmpty);
    });

    test('filters out archived memories by default', () async {
      final id = await seed(
        title: 'archived-item',
        content: 'I used to work at OldCo.',
      );
      await repo.archive(id);
      final retriever = MemoryRetriever(
        db: db,
        repository: repo,
        embedder: embedder,
        vectorIndex: index,
      );
      final r = await retriever.retrieve('OldCo');
      // Archived removed from vector index, so the only channel is FTS
      // which honors the status filter.
      expect(r.okOrNull, isEmpty);
    });
  });
}

// A no-op helper the tests don't actually need — keeps diffs focused
// on the retriever contract. Inlined to avoid polluting the public
// repository surface.
extension _IdNoop on MemoryRepository {
  MemoryId? id$$noop() => null;
}
