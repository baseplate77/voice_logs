import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart';

import '../asr/models/transcript.dart';
import '../capture/models/speech_segment.dart';
import '../core/errors.dart';
import '../core/result.dart';
import '../embed/embedder.dart';
import '../llm/models/cleaned_transcript.dart';
import 'app_database.dart';
import 'models/voice_log_record.dart';
import 'vector_index.dart';

/// How audio files get deleted on cascade. File I/O is abstracted so
/// tests don't need a real filesystem; production just passes
/// `File(path).delete`.
typedef AudioFileDeleter = Future<void> Function(String path);

/// High-level store for voice logs — the layer every other piece of the
/// app uses to read and write persisted data.
///
/// Four stores behind the scenes:
///   1. Drift / SQLCipher (Phase 4b): voice_logs, transcript_chunks,
///      entities, chunk_entities + FTS5.
///   2. ObjectBox (Phase 4c): HNSW index of chunk embeddings keyed by
///      `chunks.objectbox_id`.
///   3. Embedder (Phase 4a): produces the vectors during ingest.
///   4. Filesystem: audio WAVs; [deleteLog] removes the file too.
///
/// Every public method returns a [Result]. Storage failures (disk
/// full, SQLCipher key mismatch, schema violation) surface as
/// [StorageError]; programmer errors (passing an empty transcript to
/// `ingest`) throw.
class VoiceLogRepository {
  VoiceLogRepository(
    this._db, {
    required Embedder embedder,
    VectorIndex? vectorIndex,
    AudioFileDeleter? audioFileDeleter,
  })  : _embedder = embedder,
        _vectorIndex = vectorIndex,
        _audioFileDeleter = audioFileDeleter ?? _defaultDeleteAudioFile;

  final AppDatabase _db;
  final Embedder _embedder;

  /// Nullable so tests that don't care about vectors (Phase 4b-era
  /// tests) can skip the vector pipeline. When null, ingest writes no
  /// vectors and vectorSearch returns an empty list.
  final VectorIndex? _vectorIndex;

  final AudioFileDeleter _audioFileDeleter;

  static Future<void> _defaultDeleteAudioFile(String path) async {
    final f = File(path);
    if (f.existsSync()) await f.delete();
  }

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

        // Stash the inserted chunk ids on the outer closure so the
        // post-transaction vector write can key each embedding to its
        // chunk row.
        _pendingChunkIds = insertedChunkIds;
      });
      final chunkIds = _pendingChunkIds;
      _pendingChunkIds = const <int>[];

      // Vectors live OUTSIDE the Drift transaction — ObjectBox isn't
      // enrolled in it, and holding the Drift tx open while we embed
      // would serialise everything. A mid-crash here leaves chunks
      // with `objectbox_id = 0`; [cleanupOrphanVectors] reconciles on
      // next startup. Phase 7's re-embed job would re-fill them.
      final index = _vectorIndex;
      if (index != null && chunkIds.isNotEmpty) {
        final texts = cleaned.chunks
            .map((c) => c.text)
            .toList(growable: false);
        final embedResult = await _embedder.embedPassages(texts);
        if (embedResult.isErr) {
          // Chunks are durable already — we just didn't index them.
          return Err<VoiceLogId, AppError>(embedResult.errOrNull!);
        }
        final vectors = embedResult.okOrNull!;
        for (var i = 0; i < chunkIds.length; i++) {
          final vId = index.put(
            logId: recording.id,
            embedding: vectors[i],
          );
          await (_db.update(_db.transcriptChunks)
                ..where((c) => c.id.equals(chunkIds[i])))
              .write(TranscriptChunksCompanion(objectboxId: Value(vId)));
        }
      }

      return Ok<VoiceLogId, AppError>(VoiceLogId(recording.id));
    } on Object catch (e, st) {
      return Err<VoiceLogId, AppError>(
        StorageError('ingest failed', cause: e, stackTrace: st),
      );
    }
  }

  /// Holds chunk ids from the most recent ingest transaction so the
  /// post-transaction vector-write step can key each embedding back
  /// to its chunk row. Written inside the tx, read once outside.
  List<int> _pendingChunkIds = const <int>[];

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

  /// Cosine-similarity search against the ObjectBox HNSW index.
  /// Returns chunks ordered most-similar first. The caller owns query
  /// embedding (prefixed with `"query: "` and L2-normalised by the
  /// [Embedder]).
  Future<Result<List<ChunkRecord>, AppError>> vectorSearch(
    Float32List queryVec, {
    int limit = 20,
  }) async {
    final index = _vectorIndex;
    if (index == null) {
      return const Ok<List<ChunkRecord>, AppError>(<ChunkRecord>[]);
    }
    if (queryVec.length != _embedder.embeddingDim) {
      return Err<List<ChunkRecord>, AppError>(
        StorageError(
          'queryVec has dim ${queryVec.length}, '
          'expected ${_embedder.embeddingDim}',
        ),
      );
    }
    try {
      final matches = index.nearest(queryVec, limit);
      if (matches.isEmpty) {
        return const Ok<List<ChunkRecord>, AppError>(<ChunkRecord>[]);
      }
      // Preserve VectorIndex ordering while doing a single
      // Drift IN () lookup to hydrate the chunk rows.
      final vectorIds = matches.map((m) => m.vectorId).toList();
      final chunkRows = await (_db.select(_db.transcriptChunks)
            ..where((c) => c.objectboxId.isIn(vectorIds)))
          .get();
      final byVectorId = {for (final r in chunkRows) r.objectboxId: r};
      final ordered = <ChunkRecord>[];
      for (final match in matches) {
        final row = byVectorId[match.vectorId];
        if (row != null) ordered.add(_toChunkRecord(row));
      }
      return Ok<List<ChunkRecord>, AppError>(ordered);
    } on Object catch (e, st) {
      return Err<List<ChunkRecord>, AppError>(
        StorageError('vectorSearch failed', cause: e, stackTrace: st),
      );
    }
  }

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

  /// Delete a log across every store: ObjectBox vectors → audio file
  /// → Drift rows (voice_logs + transcript_chunks + chunk_entities +
  /// FTS5 via triggers).
  ///
  /// Ordering matters: vectors first (keyed by logId index) because a
  /// crash mid-cascade is recoverable via Drift's FK integrity —
  /// orphaned vectors are detected by [cleanupOrphanVectors] on next
  /// boot. If Drift was deleted first we'd be chasing phantom row ids
  /// in the vector store with no way to match them back.
  ///
  /// Entities are intentionally NOT cascade-deleted — they can still
  /// be referenced by other logs.
  Future<Result<void, AppError>> deleteLog(VoiceLogId id) async {
    try {
      // 1. Vectors, keyed by logId (denormalised onto ChunkVector).
      _vectorIndex?.removeByLogId(id.raw);

      // 2. Audio file. Look it up before deleting the log row.
      final log = await (_db.select(_db.voiceLogs)
            ..where((l) => l.id.equals(id.raw)))
          .getSingleOrNull();
      if (log != null) {
        try {
          await _audioFileDeleter(log.audioPath);
        } on Object catch (_) {
          // Non-fatal: audio file may already be gone on a retry.
        }
      }

      // 3. Drift rows.
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

  /// Remove ChunkVector rows that no longer have a matching chunk in
  /// Drift. Should be called once at app startup — resolves the gap
  /// between ObjectBox and Drift when a crash split the two stores.
  ///
  /// Returns the number of vectors removed.
  Future<Result<int, AppError>> cleanupOrphanVectors() async {
    final index = _vectorIndex;
    if (index == null) return const Ok<int, AppError>(0);
    try {
      final vectorIds = index.allIds();
      if (vectorIds.isEmpty) return const Ok<int, AppError>(0);
      final usedRows = await (_db.selectOnly(_db.transcriptChunks)
            ..addColumns([_db.transcriptChunks.objectboxId])
            ..where(_db.transcriptChunks.objectboxId.isIn(vectorIds)))
          .get();
      final used = <int>{
        for (final r in usedRows)
          r.read(_db.transcriptChunks.objectboxId) ?? 0,
      };
      final orphaned =
          vectorIds.where((id) => !used.contains(id)).toList(growable: false);
      if (orphaned.isNotEmpty) {
        index.removeByIds(orphaned);
      }
      return Ok<int, AppError>(orphaned.length);
    } on Object catch (e, st) {
      return Err<int, AppError>(
        StorageError(
          'cleanupOrphanVectors failed',
          cause: e,
          stackTrace: st,
        ),
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
