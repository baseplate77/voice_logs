import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/drift.dart';

import '../asr/models/transcript.dart';
import '../capture/models/speech_segment.dart';
import '../core/errors.dart';
import '../core/result.dart';
import '../llm/models/cleaned_transcript.dart';
import 'app_database.dart';
import 'models/voice_log_record.dart';

/// High-level store for voice logs — the layer every other piece of the
/// app uses to read and write persisted data.
///
/// Phase 4b scope: Drift-backed CRUD + FTS5 keyword search. Vector
/// search is a stub; Phase 4c wires it to an ObjectBox HNSW index and
/// that's where [vectorSearch] starts returning real results.
///
/// Every public method returns a [Result]. Storage failures (disk
/// full, SQLCipher key mismatch, schema violation) surface as
/// [StorageError]; programmer errors (passing an empty transcript to
/// `ingest`) throw.
class VoiceLogRepository {
  VoiceLogRepository(this._db);

  final AppDatabase _db;

  /// Write a full recording + its cleaned transcript in one
  /// transaction. Returns the [VoiceLogId] of the inserted row.
  ///
  /// Ordering:
  ///   1. insert `voice_logs` (id = recording.id)
  ///   2. insert one row per `cleaned.chunks` into `chunks` (FTS5
  ///      triggers populate `chunks_fts` transparently)
  ///   3. upsert one row per unique `cleaned.entities` into
  ///      `entities`, updating `last_seen`
  ///   4. insert `chunk_entities` links (one per chunk × matching
  ///      entity by canonical name)
  ///
  /// A mid-ingest crash is recoverable: the whole block runs in a
  /// Drift transaction so partial writes roll back. The Phase 4c
  /// orphan-cleanup job (ObjectBox vs SQLCipher reconciliation) is
  /// documented there.
  Future<Result<VoiceLogId, AppError>> ingest({
    required RecordingHandle recording,
    required Transcript transcript,
    required CleanedTranscript cleaned,
  }) async {
    if (recording.id.isEmpty) {
      throw ArgumentError('RecordingHandle.id must be non-empty');
    }
    try {
      await _db.transaction(() async {
        await _db.into(_db.voiceLogs).insertOnConflictUpdate(
              VoiceLogsCompanion(
                id: Value(recording.id),
                startedAt: Value(recording.startedAt.millisecondsSinceEpoch),
                durationMs: Value(recording.durationMs),
                audioPath: Value(recording.audioFilePath),
                rawTranscript: Value(
                  transcript.text.isEmpty ? null : transcript.text,
                ),
                cleanedTranscript: Value(cleaned.text),
                language: Value(transcript.detectedLanguage),
              ),
            );

        // Insert chunks — the fixed-width fallback path produces a
        // topicHint of "(fixed-width fallback)" which we pass through
        // as-is so downstream code can surface it in UI for debugging.
        final insertedChunkIds = <int>[];
        for (final chunk in cleaned.chunks) {
          final id = await _db.into(_db.transcriptChunks).insert(
                TranscriptChunksCompanion(
                  logId: Value(recording.id),
                  content: Value(chunk.text),
                  startChar: Value(chunk.startChar),
                  endChar: Value(chunk.endChar),
                  topicHint: Value(chunk.topicHint),
                  createdAt: Value(
                    recording.startedAt.millisecondsSinceEpoch,
                  ),
                ),
              );
          insertedChunkIds.add(id);
        }

        // Upsert entities by canonical name (case-insensitive). Drift
        // doesn't have a native "where canonical_name LIKE ? case-
        // insensitive" upsert so we first SELECT, then either INSERT
        // or UPDATE last_seen + merge aliases.
        final nameToEntityId = <String, int>{};
        for (final entity in cleaned.entities) {
          final key = entity.name.toLowerCase();
          final existing = await (_db.select(_db.entities)
                ..where((e) => e.canonicalName.lower().equals(key))
                ..limit(1))
              .getSingleOrNull();

          if (existing == null) {
            final entityId = await _db.into(_db.entities).insert(
                  EntitiesCompanion(
                    canonicalName: Value(entity.name),
                    kind: Value(entity.kind),
                    aliasesJson: Value(jsonEncode(entity.aliases)),
                    firstSeen: Value(
                      recording.startedAt.millisecondsSinceEpoch,
                    ),
                    lastSeen: Value(
                      recording.startedAt.millisecondsSinceEpoch,
                    ),
                  ),
                );
            nameToEntityId[key] = entityId;
          } else {
            // Merge aliases with the new set, keeping order and de-duping.
            final merged = <String>{
              ...(jsonDecode(existing.aliasesJson) as List<dynamic>)
                  .cast<String>(),
              ...entity.aliases,
            }.toList(growable: false);
            await (_db.update(_db.entities)
                  ..where((e) => e.id.equals(existing.id)))
                .write(
              EntitiesCompanion(
                aliasesJson: Value(jsonEncode(merged)),
                lastSeen: Value(
                  recording.startedAt.millisecondsSinceEpoch,
                ),
              ),
            );
            nameToEntityId[key] = existing.id;
          }
        }

        // Chunk-entity links: for each chunk, create a link row per
        // entity that appears in the chunk's `entityRefs` list
        // (matched by lowercased canonical name).
        for (var i = 0; i < cleaned.chunks.length; i++) {
          final chunk = cleaned.chunks[i];
          final chunkId = insertedChunkIds[i];
          for (final ref in chunk.entityRefs) {
            final entityId = nameToEntityId[ref.toLowerCase()];
            if (entityId == null) continue;
            await _db.into(_db.chunkEntities).insertOnConflictUpdate(
                  ChunkEntitiesCompanion(
                    chunkId: Value(chunkId),
                    entityId: Value(entityId),
                  ),
                );
          }
        }
      });
      return Ok<VoiceLogId, AppError>(VoiceLogId(recording.id));
    } on Object catch (e, st) {
      return Err<VoiceLogId, AppError>(
        StorageError('ingest failed', cause: e, stackTrace: st),
      );
    }
  }

  /// BM25-ranked keyword search across all chunks.
  Future<Result<List<ChunkRecord>, AppError>> keywordSearch(
    String query, {
    int limit = 20,
  }) async {
    final sanitised = _sanitiseFtsQuery(query);
    if (sanitised.isEmpty) {
      return const Ok<List<ChunkRecord>, AppError>(<ChunkRecord>[]);
    }
    try {
      final ids = await _db.searchChunkIds(sanitised, limit: limit);
      if (ids.isEmpty) {
        return const Ok<List<ChunkRecord>, AppError>(<ChunkRecord>[]);
      }
      // Preserve BM25 order while doing a single IN () lookup.
      final rows = await (_db.select(_db.transcriptChunks)
            ..where((c) => c.id.isIn(ids)))
          .get();
      final byId = {for (final r in rows) r.id: r};
      final ordered = <ChunkRecord>[];
      for (final id in ids) {
        final r = byId[id];
        if (r != null) ordered.add(_toChunkRecord(r));
      }
      return Ok<List<ChunkRecord>, AppError>(ordered);
    } on Object catch (e, st) {
      return Err<List<ChunkRecord>, AppError>(
        StorageError('keywordSearch failed', cause: e, stackTrace: st),
      );
    }
  }

  /// Vector search stub. Phase 4c replaces this with an ObjectBox HNSW
  /// query; until then it always returns an empty list.
  // ignore: use_setters_to_change_properties
  Future<Result<List<ChunkRecord>, AppError>> vectorSearch(
    Float32List queryVec, {
    int limit = 20,
  }) async =>
      const Ok<List<ChunkRecord>, AppError>(<ChunkRecord>[]);

  /// Fetch a log and its chunks + entities. Returns null (wrapped in
  /// [Ok]) when the id doesn't exist.
  Future<Result<VoiceLogRecord?, AppError>> getLog(VoiceLogId id) async {
    try {
      final logRow = await (_db.select(_db.voiceLogs)
            ..where((l) => l.id.equals(id.raw)))
          .getSingleOrNull();
      if (logRow == null) {
        return const Ok<VoiceLogRecord?, AppError>(null);
      }
      final chunkRows = await (_db.select(_db.transcriptChunks)
            ..where((c) => c.logId.equals(id.raw))
            ..orderBy([(c) => OrderingTerm.asc(c.startChar)]))
          .get();

      // Entities are deduped per-log via chunk_entities → entities.
      final entityRows = await _db
          .customSelect(
            '''
            SELECT DISTINCT e.id, e.canonical_name, e.kind, e.aliases_json,
                            e.first_seen, e.last_seen
            FROM entities e
            JOIN chunk_entities ce ON ce.entity_id = e.id
            JOIN transcript_chunks c ON c.id = ce.chunk_id
            WHERE c.log_id = ?
            ORDER BY e.canonical_name
            ''',
            variables: [Variable.withString(id.raw)],
            readsFrom: {_db.entities, _db.chunkEntities, _db.transcriptChunks},
          )
          .get();

      final entities = entityRows.map((r) {
        final aliases = (jsonDecode(r.read<String>('aliases_json'))
                as List<dynamic>)
            .cast<String>();
        return Entity(
          name: r.read<String>('canonical_name'),
          kind: r.read<String>('kind'),
          aliases: aliases,
        );
      }).toList(growable: false);

      return Ok<VoiceLogRecord?, AppError>(
        VoiceLogRecord(
          id: id,
          startedAt: DateTime.fromMillisecondsSinceEpoch(logRow.startedAt),
          durationMs: logRow.durationMs,
          audioPath: logRow.audioPath,
          language: logRow.language,
          cleanedTranscript: logRow.cleanedTranscript,
          rawTranscript: logRow.rawTranscript,
          sourceTag: logRow.sourceTag,
          chunks:
              chunkRows.map(_toChunkRecord).toList(growable: false),
          entities: entities,
        ),
      );
    } on Object catch (e, st) {
      return Err<VoiceLogRecord?, AppError>(
        StorageError('getLog failed', cause: e, stackTrace: st),
      );
    }
  }

  /// Atomic delete across voice_logs → chunks → chunk_entities → FTS5.
  /// Entities are left alone (may still be referenced by other logs;
  /// orphan cleanup is an offline job).
  ///
  /// NOTE: Phase 4c adds an ObjectBox delete call inside this
  /// transaction. Also deletes the audio file on disk; not yet wired
  /// (tracked — deleting orphaned WAVs also happens in the 4c cleanup
  /// job when the log row is already gone).
  Future<Result<void, AppError>> deleteLog(VoiceLogId id) async {
    try {
      await _db.transaction(() async {
        final chunkIds = await (_db.selectOnly(_db.transcriptChunks)
              ..addColumns([_db.transcriptChunks.id])
              ..where(_db.transcriptChunks.logId.equals(id.raw)))
            .map((r) => r.read(_db.transcriptChunks.id)!)
            .get();

        if (chunkIds.isNotEmpty) {
          await (_db.delete(_db.chunkEntities)
                ..where((ce) => ce.chunkId.isIn(chunkIds)))
              .go();
          // FTS5 triggers keep chunks_fts in sync when chunks rows go
          // away, so a plain delete is enough here.
          await (_db.delete(_db.transcriptChunks)
                ..where((c) => c.id.isIn(chunkIds)))
              .go();
        }
        await (_db.delete(_db.voiceLogs)
              ..where((l) => l.id.equals(id.raw)))
            .go();
      });
      return const Ok<void, AppError>(null);
    } on Object catch (e, st) {
      return Err<void, AppError>(
        StorageError('deleteLog failed', cause: e, stackTrace: st),
      );
    }
  }

  /// Bulk listing used by UI + debug screens. Paginated by
  /// `started_at DESC` so newest first.
  Future<Result<List<VoiceLogRecord>, AppError>> listLogs({
    int limit = 50,
    int offset = 0,
  }) async {
    try {
      final rows = await (_db.select(_db.voiceLogs)
            ..orderBy([(l) => OrderingTerm.desc(l.startedAt)])
            ..limit(limit, offset: offset))
          .get();
      final out = <VoiceLogRecord>[];
      for (final row in rows) {
        final oneResult = await getLog(VoiceLogId(row.id));
        if (oneResult.isOk && oneResult.okOrNull != null) {
          out.add(oneResult.okOrNull!);
        }
      }
      return Ok<List<VoiceLogRecord>, AppError>(out);
    } on Object catch (e, st) {
      return Err<List<VoiceLogRecord>, AppError>(
        StorageError('listLogs failed', cause: e, stackTrace: st),
      );
    }
  }

  ChunkRecord _toChunkRecord(ChunkRow r) => ChunkRecord(
        id: r.id,
        logId: VoiceLogId(r.logId),
        text: r.content,
        startChar: r.startChar,
        endChar: r.endChar,
        topicHint: r.topicHint,
        createdAt: DateTime.fromMillisecondsSinceEpoch(r.createdAt),
        objectboxId: r.objectboxId,
        topicClusterId: r.topicClusterId,
      );

  /// FTS5 treats several characters as operators. Callers may pass raw
  /// user input — strip anything dangerous and wrap the whole thing as
  /// a prefix search so "price" also matches "pricing". Quoted
  /// phrases with spaces are preserved.
  static String _sanitiseFtsQuery(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return '';
    // Strip FTS5 punctuation that could blow up the parser, leave word
    // chars + spaces.
    final cleaned = trimmed.replaceAll(RegExp(r'[^\w\s\u00A0-\uFFFF]'), ' ');
    final tokens = cleaned.split(RegExp(r'\s+'))
      ..removeWhere((t) => t.isEmpty);
    if (tokens.isEmpty) return '';
    // Add `*` suffix for prefix matching on the last term; wrap each
    // token in quotes to treat hyphenated words + punctuation safely.
    final parts = <String>[];
    for (var i = 0; i < tokens.length; i++) {
      final t = tokens[i];
      if (i == tokens.length - 1) {
        parts.add('"$t"*');
      } else {
        parts.add('"$t"');
      }
    }
    return parts.join(' ');
  }
}
