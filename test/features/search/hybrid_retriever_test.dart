import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voxsynth/core/db/database.dart';
import 'package:voxsynth/core/db/repositories/voice_log_repository.dart';
import 'package:voxsynth/core/result.dart';
import 'package:voxsynth/features/search/embedder.dart';
import 'package:voxsynth/features/search/hybrid_retriever.dart';
import 'package:voxsynth/features/search/search_filters.dart';
import 'package:voxsynth/features/search/segment_repository.dart';
import 'package:voxsynth/features/search/vec_store.dart';

final _emptyEmbedding = Uint8List(4);

Future<void> _insertSegment(
  VoxSynthDatabase db, {
  required String id,
  required String logId,
  required int startMs,
  required int endMs,
  required String text,
}) async {
  await db
      .into(db.transcriptSegments)
      .insert(
        TranscriptSegmentsCompanion.insert(
          id: id,
          logId: logId,
          startTimeMs: startMs,
          endTimeMs: endMs,
          segmentText: text,
          createdAt: 0,
        ),
      );
}

Future<void> _insertEntity(
  VoxSynthDatabase db, {
  required String id,
  required String displayName,
  required String type,
}) async {
  await db
      .into(db.canonicalEntities)
      .insert(
        CanonicalEntity(
          id: id,
          displayName: displayName,
          type: type,
          mentionCount: 1,
          createdAt: 0,
          embedding: _emptyEmbedding,
        ),
      );
}

Future<void> _insertMention(
  VoxSynthDatabase db, {
  required String id,
  required String logId,
  required String text,
  required String canonicalEntityId,
  String type = 'person',
}) async {
  await db
      .into(db.entityMentions)
      .insert(
        EntityMention(
          id: id,
          logId: logId,
          mentionText: text,
          type: type,
          charStart: 0,
          charEnd: text.length,
          canonicalEntityId: canonicalEntityId,
        ),
      );
}

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

  test('FTS snippet is an excerpt around the matched keyword', () async {
    final db = VoxSynthDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final repo = VoiceLogRepository(db);
    await repo.insertRecorded(
      id: 'log_1',
      createdAt: DateTime(2026, 5, 7),
      durationMs: 1000,
      audioPath: 'audio/log_1.wav',
      rawTranscript:
          'Morning notes about breakfast and commute. '
          'Then a long section about project atlas planning with Shivani. '
          'Finally a closing thought about dinner.',
    );

    final retriever = HybridRetriever(
      db: db,
      embedder: _FailingEmbedder(),
      vecStore: VecStore(SegmentRepository(db)),
    );

    final res = await retriever.search('shivani');
    expect(res, isA<Ok<List<SearchHit>, RetrieverError>>());
    final hits = (res as Ok<List<SearchHit>, RetrieverError>).value;
    expect(hits.single.snippet.toLowerCase(), contains('shivani'));
    expect(hits.single.snippet.length, lessThan(130));
  });

  test('natural-language question drops filler words for FTS', () async {
    final db = VoxSynthDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final repo = VoiceLogRepository(db);
    await repo.insertRecorded(
      id: 'log_rahul',
      createdAt: DateTime(2026, 5, 7),
      durationMs: 1000,
      audioPath: 'audio/log_rahul.wav',
      rawTranscript: 'Rahul shared the launch plan for Atlas.',
    );

    final retriever = HybridRetriever(
      db: db,
      embedder: _FailingEmbedder(),
      vecStore: VecStore(SegmentRepository(db)),
    );

    final res = await retriever.search('what did Rahul say');
    final hits = (res as Ok<List<SearchHit>, RetrieverError>).value;
    expect(hits.map((h) => h.logId), ['log_rahul']);
    expect(hits.single.highlightTerms, contains('rahul'));
    expect(hits.single.highlightTerms, isNot(contains('say')));
    expect(hits.single.snippet, contains('Rahul'));
  });

  test('query entity path handles a misspelled person name', () async {
    final db = VoxSynthDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final repo = VoiceLogRepository(db);
    await repo.insertRecorded(
      id: 'log_john',
      createdAt: DateTime(2026, 5, 7),
      durationMs: 1000,
      audioPath: 'audio/log_john.wav',
      rawTranscript: 'Met with John about the prototype.',
    );
    await _insertEntity(
      db,
      id: 'ent_john',
      displayName: 'John',
      type: 'person',
    );
    await _insertMention(
      db,
      id: 'm_john',
      logId: 'log_john',
      text: 'John',
      canonicalEntityId: 'ent_john',
    );

    final retriever = HybridRetriever(
      db: db,
      embedder: _FailingEmbedder(),
      vecStore: VecStore(SegmentRepository(db)),
    );

    final res = await retriever.search('what did Jhon say');
    final hits = (res as Ok<List<SearchHit>, RetrieverError>).value;
    expect(hits.map((h) => h.logId), ['log_john']);
    expect(hits.single.matchedVia, contains(MatchSource.entity));
    expect(hits.single.matchedEntityNames, contains('John'));
    expect(hits.single.highlightTerms, contains('john'));
  });

  test(
    'date-only natural-language question returns logs from yesterday',
    () async {
      final db = VoxSynthDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final repo = VoiceLogRepository(db);
      await repo.insertRecorded(
        id: 'log_yesterday',
        createdAt: DateTime(2026, 5, 22, 10),
        durationMs: 1000,
        audioPath: 'audio/yesterday.wav',
        rawTranscript: 'Spoke through a product idea.',
      );
      await repo.insertRecorded(
        id: 'log_today',
        createdAt: DateTime(2026, 5, 23, 10),
        durationMs: 1000,
        audioPath: 'audio/today.wav',
        rawTranscript: 'Today notes.',
      );

      final retriever = HybridRetriever(
        db: db,
        embedder: _FailingEmbedder(),
        vecStore: VecStore(SegmentRepository(db)),
        now: () => DateTime(2026, 5, 23, 12),
      );

      final res = await retriever.search('what did I say yesterday');
      final hits = (res as Ok<List<SearchHit>, RetrieverError>).value;
      expect(hits.map((h) => h.logId), ['log_yesterday']);
      expect(hits.single.matchedVia, contains(MatchSource.date));
      expect(hits.single.localReason, contains('yesterday'));
    },
  );

  test('natural-language idea query combines keyword and yesterday', () async {
    final db = VoxSynthDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final repo = VoiceLogRepository(db);
    await repo.insertRecorded(
      id: 'log_idea_yesterday',
      createdAt: DateTime(2026, 5, 22, 10),
      durationMs: 1000,
      audioPath: 'audio/idea_yesterday.wav',
      rawTranscript: 'I got an idea for the offline memory search.',
    );
    await repo.insertRecorded(
      id: 'log_idea_today',
      createdAt: DateTime(2026, 5, 23, 10),
      durationMs: 1000,
      audioPath: 'audio/idea_today.wav',
      rawTranscript: 'Another idea from today.',
    );

    final retriever = HybridRetriever(
      db: db,
      embedder: _FailingEmbedder(),
      vecStore: VecStore(SegmentRepository(db)),
      now: () => DateTime(2026, 5, 23, 12),
    );

    final res = await retriever.search('what idea did I get yesterday');
    final hits = (res as Ok<List<SearchHit>, RetrieverError>).value;
    expect(hits.map((h) => h.logId), ['log_idea_yesterday']);
    expect(hits.single.matchedVia, contains(MatchSource.fts));
    expect(hits.single.matchedVia, contains(MatchSource.date));
    expect(hits.single.highlightTerms, contains('idea'));
    expect(hits.single.snippet.toLowerCase(), contains('idea'));
  });

  test('FTS hit pinpoints the transcript segment containing the keyword', () async {
    final db = VoxSynthDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final repo = VoiceLogRepository(db);
    await repo.insertRecorded(
      id: 'log_pin',
      createdAt: DateTime(2026, 5, 7),
      durationMs: 30000,
      audioPath: 'audio/log_pin.wav',
      rawTranscript:
          'Morning notes about breakfast. '
          'Coffee with Shivani at Cafe Coffee Day, she mentioned the Atlas deadline. '
          'Closing thought about dinner.',
    );
    await _insertSegment(
      db,
      id: 'seg_0',
      logId: 'log_pin',
      startMs: 0,
      endMs: 4500,
      text: 'Morning notes about breakfast.',
    );
    await _insertSegment(
      db,
      id: 'seg_1',
      logId: 'log_pin',
      startMs: 4500,
      endMs: 18000,
      text:
          'Coffee with Shivani at Cafe Coffee Day, she mentioned the Atlas deadline.',
    );
    await _insertSegment(
      db,
      id: 'seg_2',
      logId: 'log_pin',
      startMs: 18000,
      endMs: 25000,
      text: 'Closing thought about dinner.',
    );

    final retriever = HybridRetriever(
      db: db,
      embedder: _FailingEmbedder(),
      vecStore: VecStore(SegmentRepository(db)),
    );

    final res = await retriever.search('shivani');
    final hit = (res as Ok<List<SearchHit>, RetrieverError>).value.single;
    expect(hit.bestSegmentId, 'seg_1');
    expect(hit.bestSegmentStartMs, 4500);
    expect(hit.bestSegmentEndMs, 18000);
    expect(hit.localReason, contains('Keyword'));
    expect(hit.localReason, contains('0:04'));
  });

  test(
    'entity facet filter restricts to logs mentioning a selected entity',
    () async {
      final db = VoxSynthDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final repo = VoiceLogRepository(db);
      await repo.insertRecorded(
        id: 'log_with',
        createdAt: DateTime(2026, 5, 7),
        durationMs: 1000,
        audioPath: 'audio/log_with.wav',
        rawTranscript: 'coffee discussion',
      );
      await repo.insertRecorded(
        id: 'log_without',
        createdAt: DateTime(2026, 5, 7),
        durationMs: 1000,
        audioPath: 'audio/log_without.wav',
        rawTranscript: 'coffee alone',
      );
      await _insertEntity(
        db,
        id: 'ent_shivani',
        displayName: 'Shivani',
        type: 'person',
      );
      await _insertMention(
        db,
        id: 'm1',
        logId: 'log_with',
        text: 'Shivani',
        canonicalEntityId: 'ent_shivani',
      );

      final retriever = HybridRetriever(
        db: db,
        embedder: _FailingEmbedder(),
        vecStore: VecStore(SegmentRepository(db)),
      );

      final filters = const SearchFilters().toggleEntity(
        EntityFacet.person,
        'ent_shivani',
      );
      final res = await retriever.search('coffee', filters: filters);
      final hits = (res as Ok<List<SearchHit>, RetrieverError>).value;
      expect(hits.map((h) => h.logId), ['log_with']);
      expect(hits.single.matchedEntityNames, contains('Shivani'));
      expect(hits.single.localReason, contains('Shivani'));
    },
  );

  test(
    'entity AND-across-facets excludes logs missing one facet group',
    () async {
      final db = VoxSynthDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final repo = VoiceLogRepository(db);
      await repo.insertRecorded(
        id: 'log_both',
        createdAt: DateTime(2026, 5, 7),
        durationMs: 1000,
        audioPath: 'audio/log_both.wav',
        rawTranscript: 'coffee chat',
      );
      await repo.insertRecorded(
        id: 'log_person_only',
        createdAt: DateTime(2026, 5, 7),
        durationMs: 1000,
        audioPath: 'audio/log_person.wav',
        rawTranscript: 'coffee chat',
      );
      await _insertEntity(
        db,
        id: 'ent_shivani',
        displayName: 'Shivani',
        type: 'person',
      );
      await _insertEntity(
        db,
        id: 'ent_ccd',
        displayName: 'Cafe Coffee Day',
        type: 'place',
      );
      await _insertMention(
        db,
        id: 'm1',
        logId: 'log_both',
        text: 'Shivani',
        canonicalEntityId: 'ent_shivani',
      );
      await _insertMention(
        db,
        id: 'm2',
        logId: 'log_both',
        text: 'Cafe Coffee Day',
        canonicalEntityId: 'ent_ccd',
        type: 'place',
      );
      await _insertMention(
        db,
        id: 'm3',
        logId: 'log_person_only',
        text: 'Shivani',
        canonicalEntityId: 'ent_shivani',
      );

      final retriever = HybridRetriever(
        db: db,
        embedder: _FailingEmbedder(),
        vecStore: VecStore(SegmentRepository(db)),
      );

      final filters = const SearchFilters()
          .toggleEntity(EntityFacet.person, 'ent_shivani')
          .toggleEntity(EntityFacet.place, 'ent_ccd');
      final res = await retriever.search('coffee', filters: filters);
      final hits = (res as Ok<List<SearchHit>, RetrieverError>).value;
      expect(hits.map((h) => h.logId), ['log_both']);
    },
  );

  test('date range filter excludes logs outside the window', () async {
    final db = VoxSynthDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final repo = VoiceLogRepository(db);
    await repo.insertRecorded(
      id: 'log_old',
      createdAt: DateTime(2026, 1, 2),
      durationMs: 1000,
      audioPath: 'audio/old.wav',
      rawTranscript: 'old coffee',
    );
    await repo.insertRecorded(
      id: 'log_new',
      createdAt: DateTime(2026, 5, 10),
      durationMs: 1000,
      audioPath: 'audio/new.wav',
      rawTranscript: 'new coffee',
    );

    final retriever = HybridRetriever(
      db: db,
      embedder: _FailingEmbedder(),
      vecStore: VecStore(SegmentRepository(db)),
    );

    final filters = const SearchFilters().copyWith(
      dateRange: DateRange(start: DateTime(2026, 5, 2)),
    );
    final res = await retriever.search('coffee', filters: filters);
    final hits = (res as Ok<List<SearchHit>, RetrieverError>).value;
    expect(hits.map((h) => h.logId), ['log_new']);
  });
}
