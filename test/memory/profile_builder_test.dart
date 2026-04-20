import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:voxsynth/llm/llm_runner.dart';
import 'package:voxsynth/memory/memory_repository.dart';
import 'package:voxsynth/memory/memory_vector_index.dart';
import 'package:voxsynth/memory/models/memory.dart';
import 'package:voxsynth/memory/profile_builder.dart';
import 'package:voxsynth/store/app_database.dart';
import 'package:voxsynth/store/database_factory.dart';

Future<AppDatabase> _openDb() async {
  final db = openInMemoryAppDatabase();
  await db.customSelect('SELECT 1').get();
  return db;
}

FactMemory _fact(MemoryId id, String content) => FactMemory(
      id: id,
      title: content.substring(0, content.length.clamp(0, 20)),
      content: content,
      status: MemoryStatus.active,
      confidence: 0.9,
      createdAt: DateTime.utc(2026, 4, 18),
      updatedAt: DateTime.utc(2026, 4, 18),
    );

void main() {
  group('ProfileBuilder', () {
    late AppDatabase db;
    late MemoryRepository repo;

    setUp(() async {
      db = await _openDb();
      repo = MemoryRepository(
        db,
        vectorIndex: InMemoryMemoryVectorIndex(),
        idSource: math.Random(1),
      );
    });

    tearDown(() => db.close());

    test('current() returns empty when the cache is fresh and blank',
        () async {
      final runner = FakeLlmRunner();
      await runner.load();
      final builder = ProfileBuilder(repository: repo, runner: runner);
      final r = await builder.current();
      expect(r.okOrNull!.summary, '');
      expect(r.okOrNull!.isStale, isFalse);
    });

    test('markStale + current triggers a rebuild that stores the summary',
        () async {
      await repo.save(_fact(repo.newId(), 'I work at Acme.'));
      await repo.markProfileStale();
      final runner = FakeLlmRunner(
        responses: const <String>['Engineer at Acme, shipping VoxSynth v1.'],
      );
      await runner.load();
      final builder = ProfileBuilder(
        repository: repo,
        runner: runner,
        clock: () => DateTime.utc(2026, 4, 20),
      );
      final r = await builder.current();
      expect(r.isOk, isTrue);
      expect(r.okOrNull!.summary,
          'Engineer at Acme, shipping VoxSynth v1.');
      expect(r.okOrNull!.isStale, isFalse);
      // Cached: second call doesn't re-invoke the runner.
      final second = await builder.current();
      expect(second.okOrNull!.summary, r.okOrNull!.summary);
      expect(runner.callCount, 1);
    });

    test('truncates an over-long summary on word boundary', () async {
      await repo.save(_fact(repo.newId(), 'I have many opinions.'));
      await repo.markProfileStale();
      final huge = 'word ' * 4000;
      final runner = FakeLlmRunner(responses: <String>[huge]);
      await runner.load();
      final builder = ProfileBuilder(repository: repo, runner: runner);
      final r = await builder.rebuild();
      expect(r.isOk, isTrue);
      final summary = r.okOrNull!.summary;
      expect(summary.length, lessThanOrEqualTo(1501));
      expect(summary.endsWith('…'), isTrue);
    });

    test('empty memory store short-circuits without an LLM call', () async {
      await repo.markProfileStale();
      final runner = FakeLlmRunner();
      await runner.load();
      final builder = ProfileBuilder(repository: repo, runner: runner);
      final r = await builder.rebuild();
      expect(r.isOk, isTrue);
      expect(r.okOrNull!.summary, '');
      expect(runner.callCount, 0);
    });
  });
}
