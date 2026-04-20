import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:voxsynth/core/errors.dart';
import 'package:voxsynth/core/result.dart';
import 'package:voxsynth/embed/embedder.dart';
import 'package:voxsynth/llm/llm_runner.dart';
import 'package:voxsynth/memory/memory_consolidator.dart';
import 'package:voxsynth/memory/memory_repository.dart';
import 'package:voxsynth/memory/memory_vector_index.dart';
import 'package:voxsynth/memory/models/memory.dart';
import 'package:voxsynth/memory/models/memory_candidate.dart';
import 'package:voxsynth/store/app_database.dart';
import 'package:voxsynth/store/database_factory.dart';

Future<AppDatabase> _openDb() async {
  final db = openInMemoryAppDatabase();
  await db.customSelect('SELECT 1').get();
  return db;
}

/// Always returns the same unit vector, forcing cosine similarity to 1.0
/// so the consolidator's prefilter (> 0.85) fires and the judge runs.
class _FixedEmbedder implements Embedder {
  _FixedEmbedder();

  @override
  int get embeddingDim => 384;

  final Float32List _v = () {
    final out = Float32List(384);
    out[0] = 1.0;
    return out;
  }();

  @override
  Future<Result<void, AppError>> load() async =>
      const Ok<void, AppError>(null);

  @override
  Future<Result<List<Float32List>, AppError>> embedPassages(
    List<String> texts,
  ) async =>
      Ok<List<Float32List>, AppError>(
        List<Float32List>.generate(texts.length, (_) => _v),
      );

  @override
  Future<Result<Float32List, AppError>> embedQuery(String text) async =>
      Ok<Float32List, AppError>(_v);

  @override
  Future<void> dispose() async {}
}

MemoryCandidate _candidate({
  MemoryKind kind = MemoryKind.fact,
  String title = 'works-at-acme',
  String content = 'I work at Acme as a senior PM.',
  double confidence = 0.9,
  DateTime? occurredAt,
  GoalState? goalState,
  List<int> sourceChunkIds = const <int>[],
}) =>
    MemoryCandidate(
      kind: kind,
      title: title,
      content: content,
      confidence: confidence,
      sourceChunkIds: sourceChunkIds,
      occurredAt: occurredAt,
      goalState: goalState,
    );

void main() {
  group('MemoryConsolidator', () {
    late AppDatabase db;
    late InMemoryMemoryVectorIndex index;
    late MemoryRepository repo;
    late Embedder embedder;

    setUp(() async {
      db = await _openDb();
      index = InMemoryMemoryVectorIndex();
      repo = MemoryRepository(
        db,
        vectorIndex: index,
        idSource: math.Random(42),
      );
      embedder = _FixedEmbedder();
      await embedder.load();
    });

    tearDown(() => db.close());

    test('unrelated candidates insert as new memories', () async {
      final judge = FakeLlmRunner(
        responses: const <String>['{"verdict":"unrelated"}'],
      );
      await judge.load();
      final cons = MemoryConsolidator(
        repository: repo,
        embedder: embedder,
        vectorIndex: index,
        judgeRunner: judge,
        entityResolver: (_) async => const <String, int>{},
      );
      final r = await cons.consolidate(<MemoryCandidate>[
        _candidate(title: 'first'),
        _candidate(title: 'second', content: 'Completely different fact.'),
      ]);
      expect(r.isOk, isTrue);
      final out = r.okOrNull!;
      expect(out.created.length, 2);
      expect(out.merged, isEmpty);
      expect(out.superseded, isEmpty);
    });

    test('duplicate verdict merges into existing memory', () async {
      // Pre-populate with one fact so the second candidate finds it as
      // a near neighbour.
      final judge = FakeLlmRunner(
        // Ignored on first insert (no neighbours); used on second.
        responses: const <String>['{"verdict":"duplicate"}'],
      );
      await judge.load();
      final cons = MemoryConsolidator(
        repository: repo,
        embedder: embedder,
        vectorIndex: index,
        judgeRunner: judge,
        entityResolver: (_) async => const <String, int>{},
      );
      final first = await cons.consolidate(<MemoryCandidate>[
        _candidate(),
      ]);
      expect(first.okOrNull!.created.length, 1);

      final second = await cons.consolidate(<MemoryCandidate>[
        _candidate(
          content: 'I work at Acme as a senior PM; been there 3 years.',
        ),
      ]);
      final out = second.okOrNull!;
      expect(out.created, isEmpty);
      expect(out.merged.length, 1);
      // Longer content wins on merge.
      expect(
        out.merged.first.content,
        'I work at Acme as a senior PM; been there 3 years.',
      );
    });

    test('contradiction verdict supersedes old memory', () async {
      final judge = FakeLlmRunner(
        responses: const <String>['{"verdict":"contradiction"}'],
      );
      await judge.load();
      final cons = MemoryConsolidator(
        repository: repo,
        embedder: embedder,
        vectorIndex: index,
        judgeRunner: judge,
        entityResolver: (_) async => const <String, int>{},
      );
      final first = await cons.consolidate(<MemoryCandidate>[_candidate()]);
      expect(first.okOrNull!.created.length, 1);
      final r = await cons.consolidate(<MemoryCandidate>[
        _candidate(content: 'I now work at Beta Corp as CTO.'),
      ]);
      final out = r.okOrNull!;
      // Replacement memory lives under superseded[].replacement, not
      // created[] — a supersedence isn't a "net new" in the headline
      // count.
      expect(out.created, isEmpty);
      expect(out.superseded.length, 1);
      expect(out.superseded.first.old.status, MemoryStatus.superseded);
      expect(
        out.superseded.first.replacement.content,
        'I now work at Beta Corp as CTO.',
      );
      expect(out.isStructurallyChanged, isTrue);
    });

    test('goal without state is dropped', () async {
      final judge = FakeLlmRunner(
        responses: const <String>['{"verdict":"unrelated"}'],
      );
      await judge.load();
      final cons = MemoryConsolidator(
        repository: repo,
        embedder: embedder,
        vectorIndex: index,
        judgeRunner: judge,
        entityResolver: (_) async => const <String, int>{},
      );
      final r = await cons.consolidate(<MemoryCandidate>[
        _candidate(kind: MemoryKind.goal, title: 'ship', content: 'ship it'),
      ]);
      expect(r.okOrNull!.created, isEmpty);
      expect(r.okOrNull!.dropped, <String>['ship']);
    });
  });
}
