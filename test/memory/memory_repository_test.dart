import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:voxsynth/memory/memory_repository.dart';
import 'package:voxsynth/memory/memory_vector_index.dart';
import 'package:voxsynth/memory/models/memory.dart';
import 'package:voxsynth/store/app_database.dart';
import 'package:voxsynth/store/database_factory.dart';

Future<AppDatabase> _openDb() async {
  final db = openInMemoryAppDatabase();
  await db.customSelect('SELECT 1').get();
  return db;
}

FactMemory _fact({
  required MemoryId id,
  String title = 'works-at-acme',
  String content = 'I work at Acme as a senior PM.',
  double confidence = 0.9,
  DateTime? createdAt,
  List<int> sourceChunkIds = const <int>[],
  List<int> entityIds = const <int>[],
}) {
  final ts = createdAt ?? DateTime.utc(2026, 4, 18);
  return FactMemory(
    id: id,
    title: title,
    content: content,
    status: MemoryStatus.active,
    confidence: confidence,
    createdAt: ts,
    updatedAt: ts,
    sourceChunkIds: sourceChunkIds,
    entityIds: entityIds,
  );
}

GoalMemory _goal({
  required MemoryId id,
  String title = 'ship-v1',
  String content = 'Ship VoxSynth v1 by 2026-06-01.',
  GoalState state = GoalState.inProgress,
  DateTime? dueAt,
  DateTime? createdAt,
}) {
  final ts = createdAt ?? DateTime.utc(2026, 4, 18);
  return GoalMemory(
    id: id,
    title: title,
    content: content,
    status: MemoryStatus.active,
    confidence: 0.8,
    createdAt: ts,
    updatedAt: ts,
    state: state,
    dueAt: dueAt,
  );
}

Float32List _vec(double seed) {
  final out = Float32List(384);
  for (var i = 0; i < out.length; i++) {
    out[i] = ((seed + i) % 7) / 7.0;
  }
  return out;
}

void main() {
  group('MemoryRepository CRUD', () {
    test('save + get round-trips a fact with sources + entities', () async {
      final db = await _openDb();
      final repo = MemoryRepository(
        db,
        vectorIndex: InMemoryMemoryVectorIndex(),
        idSource: math.Random(42),
      );
      final id = repo.newId();

      // Seed a chunk + entity so the FK references resolve.
      await db.customStatement(
        '''INSERT INTO voice_logs (id, started_at, duration_ms, audio_path,
        cleaned_transcript, language) VALUES ('log-1', 0, 1, '', '', 'en')''',
      );
      await db.customStatement(
        '''INSERT INTO transcript_chunks (id, log_id, content, start_char,
        end_char, topic_hint, created_at, objectbox_id) VALUES
        (1, 'log-1', 'hi', 0, 2, 't', 0, 0)''',
      );
      await db.customStatement(
        '''INSERT INTO entities (id, canonical_name, kind, aliases_json,
        first_seen, last_seen) VALUES (1, 'Acme', 'organization', '[]', 0, 0)''',
      );

      final saveR = await repo.save(
        _fact(id: id, sourceChunkIds: const <int>[1], entityIds: const <int>[1]),
        embedding: _vec(1),
      );
      expect(saveR.isOk, isTrue);
      final saved = saveR.okOrNull!;
      expect(saved.id, id);
      expect(saved.sourceChunkIds, <int>[1]);
      expect(saved.entityIds, <int>[1]);

      final getR = await repo.get(id);
      expect(getR.okOrNull, isNotNull);
      expect(getR.okOrNull!.title, 'works-at-acme');

      await db.close();
    });

    test('list filters by kind and status', () async {
      final db = await _openDb();
      final repo = MemoryRepository(
        db,
        vectorIndex: InMemoryMemoryVectorIndex(),
        idSource: math.Random(7),
      );
      final factId = repo.newId();
      final goalId = repo.newId();
      await repo.save(_fact(id: factId), embedding: _vec(1));
      await repo.save(_goal(id: goalId), embedding: _vec(2));

      final factsR = await repo.list(kind: MemoryKind.fact);
      expect(factsR.okOrNull!.map((m) => m.id), <MemoryId>[factId]);

      final goalsR = await repo.list(kind: MemoryKind.goal);
      expect(goalsR.okOrNull!.map((m) => m.id), <MemoryId>[goalId]);
      await db.close();
    });

    test('archive removes vector but keeps row', () async {
      final db = await _openDb();
      final index = InMemoryMemoryVectorIndex();
      final repo = MemoryRepository(
        db,
        vectorIndex: index,
        idSource: math.Random(1),
      );
      final id = repo.newId();
      await repo.save(_fact(id: id), embedding: _vec(1));
      expect(index.count(), 1);
      await repo.archive(id);
      expect(index.count(), 0);
      final r = await repo.get(id);
      expect(r.okOrNull, isNotNull);
      expect(r.okOrNull!.status, MemoryStatus.archived);
      await db.close();
    });

    test('supersede links old → new and strips old vector', () async {
      final db = await _openDb();
      final index = InMemoryMemoryVectorIndex();
      final repo = MemoryRepository(
        db,
        vectorIndex: index,
        idSource: math.Random(11),
      );
      final oldId = repo.newId();
      final newId = repo.newId();
      await repo.save(_fact(id: oldId), embedding: _vec(1));
      await repo.save(
        _fact(id: newId, content: 'I now work at Beta Corp.'),
        embedding: _vec(2),
      );
      expect(index.count(), 2);

      final r = await repo.supersede(old: oldId, replacement: newId);
      expect(r.isOk, isTrue);
      final updated = await repo.get(oldId);
      expect(updated.okOrNull!.status, MemoryStatus.superseded);
      expect(updated.okOrNull!.supersededById, newId);
      // Old vector removed; replacement vector retained.
      expect(index.count(), 1);
      await db.close();
    });

    test('cleanupOrphanVectors removes stale entries', () async {
      final db = await _openDb();
      final index = InMemoryMemoryVectorIndex();
      final repo = MemoryRepository(
        db,
        vectorIndex: index,
        idSource: math.Random(23),
      );
      // Write a vector with no matching drift row.
      index.put(memoryId: 'missing', embedding: _vec(5));
      expect(index.count(), 1);

      final r = await repo.cleanupOrphanVectors();
      expect(r.isOk, isTrue);
      expect(r.okOrNull, 1);
      expect(index.count(), 0);
      await db.close();
    });
  });

  group('MemoryRepository profile cache', () {
    test('seeded row is present and not stale', () async {
      final db = await _openDb();
      final repo = MemoryRepository(db);
      final r = await repo.loadProfileSummary();
      expect(r.isOk, isTrue);
      expect(r.okOrNull!.summary, '');
      expect(r.okOrNull!.isStale, isFalse);
      await db.close();
    });

    test('markStale flips the flag', () async {
      final db = await _openDb();
      final repo = MemoryRepository(db);
      final r1 = await repo.markProfileStale();
      expect(r1.isOk, isTrue);
      final loaded = await repo.loadProfileSummary();
      expect(loaded.okOrNull!.isStale, isTrue);
      await db.close();
    });

    test('saveProfileSummary clears stale flag', () async {
      final db = await _openDb();
      final repo = MemoryRepository(db);
      await repo.markProfileStale();
      final id = repo.newId();
      final save = await repo.saveProfileSummary(
        summary: 'about me',
        sourceMemoryIds: <MemoryId>[id],
        updatedAt: DateTime.utc(2026, 4, 20),
      );
      expect(save.isOk, isTrue);
      final loaded = await repo.loadProfileSummary();
      expect(loaded.okOrNull!.summary, 'about me');
      expect(loaded.okOrNull!.isStale, isFalse);
      expect(loaded.okOrNull!.sourceMemoryIds, <MemoryId>[id]);
      await db.close();
    });
  });
}
