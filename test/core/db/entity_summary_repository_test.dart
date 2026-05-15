import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voxsynth/core/db/database.dart';
import 'package:voxsynth/core/db/repositories/canonical_entity_repository.dart';
import 'package:voxsynth/core/db/repositories/entity_summary_repository.dart';
import 'package:voxsynth/core/result.dart';
import 'package:voxsynth/features/refine/entity_summary_prompt.dart';

void main() {
  late VoxSynthDatabase db;
  late EntitySummaryRepository repo;
  late CanonicalEntityRepository canonicals;

  setUp(() async {
    db = VoxSynthDatabase(NativeDatabase.memory());
    repo = EntitySummaryRepository(db);
    canonicals = CanonicalEntityRepository(db);
    // Seed a canonical entity so FK constraints are satisfied.
    await db
        .into(db.canonicalEntities)
        .insert(
          CanonicalEntity(
            id: 'ent_shivani',
            displayName: 'Shivani',
            type: 'PERSON',
            mentionCount: 3,
            createdAt: 0,
            embedding: Uint8List(4),
          ),
        );
  });

  tearDown(() => db.close());

  test('upsert writes a new row and replaces it on conflict', () async {
    final first = await repo.upsert(
      entityId: 'ent_shivani',
      summaryText: 'You discussed Atlas with Shivani.',
      mentionCount: 3,
      modelVersion: 'gemma-3-1b-it',
    );
    expect(first, isA<Ok<EntitySummaryView, EntitySummaryError>>());

    final second = await repo.upsert(
      entityId: 'ent_shivani',
      summaryText: 'Updated blurb.',
      mentionCount: 5,
      modelVersion: 'gemma-3-1b-it',
    );
    expect(second, isA<Ok<EntitySummaryView, EntitySummaryError>>());

    final stored = await repo.find('ent_shivani');
    expect(stored, isNotNull);
    expect(stored!.summaryText, 'Updated blurb.');
    expect(stored.mentionCountAtGeneration, 5);
  });

  test('needsRegeneration is true when no row exists', () async {
    final result = await repo.needsRegeneration(
      entityId: 'ent_shivani',
      currentMentionCount: 3,
    );
    expect(result, isTrue);
  });

  test(
    'needsRegeneration is false when stored snapshot matches current',
    () async {
      await repo.upsert(
        entityId: 'ent_shivani',
        summaryText: 'blurb',
        mentionCount: 4,
        modelVersion: 'gemma-3-1b-it',
      );
      final result = await repo.needsRegeneration(
        entityId: 'ent_shivani',
        currentMentionCount: 4,
      );
      expect(result, isFalse);
    },
  );

  test(
    'needsRegeneration triggers once current grows past the threshold',
    () async {
      await repo.upsert(
        entityId: 'ent_shivani',
        summaryText: 'blurb',
        mentionCount: 4,
        modelVersion: 'gemma-3-1b-it',
      );
      // One new mention is the default threshold.
      final result = await repo.needsRegeneration(
        entityId: 'ent_shivani',
        currentMentionCount: 5,
      );
      expect(result, isTrue);
    },
  );

  test('watchForEntity emits null until a row exists', () async {
    final stream = repo.watchForEntity('ent_shivani');
    final first = await stream.first;
    expect(first, isNull);
  });

  test(
    'CanonicalEntityRepository.find resolves a seeded entity to a view',
    () async {
      final view = await canonicals.find('ent_shivani');
      expect(view, isNotNull);
      expect(view!.displayName, 'Shivani');
      expect(view.type, 'PERSON');
      expect(view.mentionCount, 3);
    },
  );

  test('CanonicalEntityRepository.find returns null for unknown id', () async {
    expect(await canonicals.find('does_not_exist'), isNull);
  });

  test('upsert round-trips structured facts JSON', () async {
    const facts = EntityStructuredFacts(
      what: 'colleague at Google',
      keyFacts: ['Lives in SF', 'Started 2024-03'],
      recentThemes: ['sprint planning', 'perf reviews'],
      relationship: 'colleague',
      lastMergedLogId: 'log_42',
      lastFullRebuildAt: 1234567,
      lastFullRebuildMentionCount: 4,
    );
    final result = await repo.upsert(
      entityId: 'ent_shivani',
      summaryText: 'You discussed Atlas with Shivani recently.',
      mentionCount: 5,
      modelVersion: 'gemma-3-1b-it',
      structuredFacts: facts,
    );
    expect(result, isA<Ok<EntitySummaryView, EntitySummaryError>>());

    final stored = await repo.find('ent_shivani');
    expect(stored, isNotNull);
    expect(stored!.structuredFacts, isNotNull);
    expect(stored.structuredFacts!.what, 'colleague at Google');
    expect(stored.structuredFacts!.keyFacts, hasLength(2));
    expect(stored.structuredFacts!.relationship, 'colleague');
    expect(stored.structuredFacts!.lastMergedLogId, 'log_42');
    expect(stored.structuredFacts!.lastFullRebuildMentionCount, 4);
  });

  test(
    'upsert with no structured facts persists null and decodes to null',
    () async {
      final result = await repo.upsert(
        entityId: 'ent_shivani',
        summaryText: 'Legacy fallback blurb.',
        mentionCount: 2,
        modelVersion: 'gemma-3-1b-it',
      );
      expect(result, isA<Ok<EntitySummaryView, EntitySummaryError>>());
      final stored = await repo.find('ent_shivani');
      expect(stored, isNotNull);
      expect(stored!.structuredFacts, isNull);
    },
  );
}
