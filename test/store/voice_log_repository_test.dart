import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:voxsynth/asr/models/transcript.dart';
import 'package:voxsynth/capture/models/speech_segment.dart';
import 'package:voxsynth/llm/models/cleaned_transcript.dart';
import 'package:voxsynth/store/app_database.dart';
import 'package:voxsynth/store/database_factory.dart';
import 'package:voxsynth/store/models/voice_log_record.dart';
import 'package:voxsynth/store/voice_log_repository.dart';

RecordingHandle _sampleHandle({
  String id = 'rec-1',
  int durationMs = 12_000,
  int startedAtMs = 1_745_000_000_000,
}) =>
    RecordingHandle(
      id: id,
      audioFilePath: '/tmp/$id.wav',
      durationMs: durationMs,
      startedAt: DateTime.fromMillisecondsSinceEpoch(startedAtMs),
    );

Transcript _sampleTranscript({
  String text = 'Today we finalised GlowUp pricing with Alice.',
  String language = 'en',
}) =>
    Transcript(
      text: text,
      words: const <Word>[],
      detectedLanguage: language,
    );

CleanedTranscript _sampleCleaned({
  String text = 'Today we finalised GlowUp pricing with Alice.',
  List<TopicChunk> chunks = const <TopicChunk>[
    TopicChunk(
      text: 'Today we finalised GlowUp pricing with Alice.',
      startChar: 0,
      endChar: 45,
      topicHint: 'pricing',
      entityRefs: <String>['GlowUp', 'Alice'],
    ),
  ],
  List<Entity> entities = const <Entity>[
    Entity(name: 'GlowUp', kind: 'product', aliases: <String>['glowup']),
    Entity(name: 'Alice', kind: 'person'),
  ],
  List<String> tags = const <String>['pricing'],
}) =>
    CleanedTranscript(
      text: text,
      chunks: chunks,
      entities: entities,
      tags: tags,
    );

Future<VoiceLogRepository> _makeRepo() async {
  final db = openInMemoryAppDatabase();
  // Force schema creation on a fresh in-memory DB. Drift's
  // MigrationStrategy.onCreate runs on first query.
  await db.customSelect('SELECT 1').get();
  return VoiceLogRepository(db);
}

Future<AppDatabase> _makeDb() async {
  final db = openInMemoryAppDatabase();
  await db.customSelect('SELECT 1').get();
  return db;
}

void main() {
  group('VoiceLogRepository.ingest', () {
    test('writes voice_log, chunks, entities, chunk_entities in one tx',
        () async {
      final db = await _makeDb();
      final repo = VoiceLogRepository(db);

      final result = await repo.ingest(
        recording: _sampleHandle(),
        transcript: _sampleTranscript(),
        cleaned: _sampleCleaned(),
      );
      expect(result.isOk, isTrue, reason: '${result.errOrNull}');

      final logs = await db.select(db.voiceLogs).get();
      expect(logs, hasLength(1));
      expect(logs.single.id, 'rec-1');

      final chunks = await db.select(db.transcriptChunks).get();
      expect(chunks, hasLength(1));
      expect(chunks.single.logId, 'rec-1');
      expect(chunks.single.content, contains('GlowUp'));

      final entities = await db.select(db.entities).get();
      expect(entities, hasLength(2));
      expect(entities.map((e) => e.canonicalName), containsAll(<String>[
        'GlowUp',
        'Alice',
      ]));

      final links = await db.select(db.chunkEntities).get();
      expect(links, hasLength(2));
    });

    test('re-ingesting the same id updates the log row and merges '
        'aliases', () async {
      final db = await _makeDb();
      final repo = VoiceLogRepository(db);

      await repo.ingest(
        recording: _sampleHandle(),
        transcript: _sampleTranscript(),
        cleaned: _sampleCleaned(
          entities: const <Entity>[
            Entity(
              name: 'GlowUp',
              kind: 'product',
              aliases: <String>['glowup'],
            ),
          ],
        ),
      );
      await repo.ingest(
        recording: _sampleHandle(),
        transcript: _sampleTranscript(),
        cleaned: _sampleCleaned(
          entities: const <Entity>[
            Entity(
              name: 'GlowUp',
              kind: 'product',
              aliases: <String>['g-up'],
            ),
          ],
        ),
      );

      // Still only one log row.
      final logs = await db.select(db.voiceLogs).get();
      expect(logs, hasLength(1));

      // And one GlowUp entity with both aliases.
      final entities = await db.select(db.entities).get();
      final glowup = entities.firstWhere(
        (e) => e.canonicalName == 'GlowUp',
      );
      expect(glowup.aliasesJson, contains('glowup'));
      expect(glowup.aliasesJson, contains('g-up'));
    });
  });

  group('VoiceLogRepository.keywordSearch', () {
    test('FTS5 returns chunks matching a prefix', () async {
      final repo = await _makeRepo();
      await repo.ingest(
        recording: _sampleHandle(id: 'a'),
        transcript: _sampleTranscript(
          text: 'We decided on pricing for GlowUp this quarter.',
        ),
        cleaned: _sampleCleaned(
          text: 'We decided on pricing for GlowUp this quarter.',
          chunks: const <TopicChunk>[
            TopicChunk(
              text: 'We decided on pricing for GlowUp this quarter.',
              startChar: 0,
              endChar: 46,
              topicHint: 'pricing',
            ),
          ],
          entities: const <Entity>[],
        ),
      );
      await repo.ingest(
        recording: _sampleHandle(id: 'b'),
        transcript: _sampleTranscript(
          text: 'Launch plan for the new feature.',
        ),
        cleaned: _sampleCleaned(
          text: 'Launch plan for the new feature.',
          chunks: const <TopicChunk>[
            TopicChunk(
              text: 'Launch plan for the new feature.',
              startChar: 0,
              endChar: 32,
              topicHint: 'launch',
            ),
          ],
          entities: const <Entity>[],
        ),
      );

      final r = await repo.keywordSearch('pric');
      expect(r.isOk, isTrue);
      final hits = r.okOrNull!;
      expect(hits, isNotEmpty);
      expect(hits.first.logId.raw, 'a');
      expect(hits.first.text, contains('pricing'));
    });

    test('empty or whitespace-only queries return no results', () async {
      final repo = await _makeRepo();
      await repo.ingest(
        recording: _sampleHandle(),
        transcript: _sampleTranscript(),
        cleaned: _sampleCleaned(),
      );

      expect((await repo.keywordSearch('')).okOrNull, isEmpty);
      expect((await repo.keywordSearch('   ')).okOrNull, isEmpty);
      // Pure punctuation also yields nothing (sanitiser strips it).
      expect((await repo.keywordSearch('???')).okOrNull, isEmpty);
    });

    test('unicode text is searchable (e5 / Hinglish compatibility)',
        () async {
      final repo = await _makeRepo();
      await repo.ingest(
        recording: _sampleHandle(),
        transcript: _sampleTranscript(text: 'आज हमने कीमत तय की'),
        cleaned: _sampleCleaned(
          text: 'आज हमने कीमत तय की',
          chunks: const <TopicChunk>[
            TopicChunk(
              text: 'आज हमने कीमत तय की',
              startChar: 0,
              endChar: 18,
              topicHint: 'pricing',
            ),
          ],
          entities: const <Entity>[],
        ),
      );
      final r = await repo.keywordSearch('कीमत');
      expect(r.okOrNull, isNotEmpty);
    });
  });

  group('VoiceLogRepository.getLog', () {
    test('returns null for an unknown id', () async {
      final repo = await _makeRepo();
      final r = await repo.getLog(const VoiceLogId('does-not-exist'));
      expect(r.isOk, isTrue);
      expect(r.okOrNull, isNull);
    });

    test('round-trips every field', () async {
      final repo = await _makeRepo();
      await repo.ingest(
        recording: _sampleHandle(),
        transcript: _sampleTranscript(),
        cleaned: _sampleCleaned(),
      );

      final r = await repo.getLog(const VoiceLogId('rec-1'));
      expect(r.isOk, isTrue, reason: 'getLog err: ${r.errOrNull}');
      final log = r.okOrNull!;
      expect(log.id.raw, 'rec-1');
      expect(log.durationMs, 12_000);
      expect(log.audioPath, '/tmp/rec-1.wav');
      expect(log.language, 'en');
      expect(log.chunks, hasLength(1));
      expect(log.chunks.first.topicHint, 'pricing');
      expect(
        log.entities.map((e) => e.name),
        containsAll(<String>['GlowUp', 'Alice']),
      );
    });
  });

  group('VoiceLogRepository.deleteLog', () {
    test('removes every trace from voice_logs/chunks/fts5/chunk_entities',
        () async {
      final db = await _makeDb();
      final repo = VoiceLogRepository(db);

      await repo.ingest(
        recording: _sampleHandle(),
        transcript: _sampleTranscript(),
        cleaned: _sampleCleaned(),
      );

      expect(await db.select(db.voiceLogs).get(), hasLength(1));
      expect(await db.select(db.transcriptChunks).get(), hasLength(1));
      expect(await db.select(db.chunkEntities).get(), hasLength(2));

      final r = await repo.deleteLog(const VoiceLogId('rec-1'));
      expect(r.isOk, isTrue);

      expect(await db.select(db.voiceLogs).get(), isEmpty);
      expect(await db.select(db.transcriptChunks).get(), isEmpty);
      expect(await db.select(db.chunkEntities).get(), isEmpty);

      // FTS5 triggers should have removed the chunk row from the
      // virtual table too.
      final fts = await db
          .customSelect('SELECT rowid FROM transcript_chunks_fts')
          .get();
      expect(fts, isEmpty);

      // Entities are intentionally NOT cascade-deleted (shared across
      // logs). They stay around, and an orphan-cleanup job will prune
      // them later.
      expect(await db.select(db.entities).get(), hasLength(2));
    });

    test('deleting a non-existent id is a no-op and returns Ok',
        () async {
      final repo = await _makeRepo();
      final r = await repo.deleteLog(const VoiceLogId('nope'));
      expect(r.isOk, isTrue);
    });
  });

  group('VoiceLogRepository.vectorSearch', () {
    test('is a stub returning empty list for Phase 4b', () async {
      final repo = await _makeRepo();
      final r = await repo.vectorSearch(Float32List(384));
      expect(r.isOk, isTrue);
      expect(r.okOrNull, isEmpty);
    });
  });

  group('VoiceLogRepository.listLogs', () {
    test('returns logs newest-first', () async {
      final repo = await _makeRepo();
      await repo.ingest(
        recording: _sampleHandle(id: 'old', startedAtMs: 1_000),
        transcript: _sampleTranscript(text: 'older log content here'),
        cleaned: _sampleCleaned(
          text: 'older log content here',
          chunks: const <TopicChunk>[
            TopicChunk(
              text: 'older log content here',
              startChar: 0,
              endChar: 22,
              topicHint: 'old',
            ),
          ],
          entities: const <Entity>[],
        ),
      );
      await repo.ingest(
        recording: _sampleHandle(id: 'new', startedAtMs: 9_999_999),
        transcript: _sampleTranscript(text: 'newer log content'),
        cleaned: _sampleCleaned(
          text: 'newer log content',
          chunks: const <TopicChunk>[
            TopicChunk(
              text: 'newer log content',
              startChar: 0,
              endChar: 17,
              topicHint: 'new',
            ),
          ],
          entities: const <Entity>[],
        ),
      );

      final r = await repo.listLogs();
      expect(r.isOk, isTrue);
      final logs = r.okOrNull!;
      expect(logs, hasLength(2));
      expect(logs.first.id.raw, 'new');
      expect(logs.last.id.raw, 'old');
    });
  });
}
