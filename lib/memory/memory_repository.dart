import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:drift/drift.dart';

import '../core/errors.dart';
import '../core/result.dart';
import '../store/app_database.dart';
import 'memory_vector_index.dart';
import 'models/memory.dart';

/// Default minimum confidence for memories returned by [list]. Archived
/// entries typically have high confidence but are filtered out by
/// `status` rather than this threshold.
const double kMemoryListMinConfidence = 0.0;

/// CRUD + indexing layer for Phase 8 memories.
///
/// Atomic across three stores:
///   1. Drift (`memories` + `memory_sources` + `memory_entities` +
///      `profile_summaries` — all in one transaction).
///   2. ObjectBox (`MemoryVector` — written after the Drift tx, same
///      pattern as [VoiceLogRepository] for chunk vectors).
///   3. FTS5 (`memories_fts` — maintained by insert/update/delete
///      triggers on the `memories` table, so callers get it for free).
///
/// Every public method returns a [Result]. Storage failures surface as
/// [StorageError]; programmer errors throw.
class MemoryRepository {
  MemoryRepository(
    this._db, {
    MemoryVectorIndex? vectorIndex,
    math.Random? idSource,
  })  : _vectorIndex = vectorIndex,
        _rand = idSource ?? math.Random.secure();

  final AppDatabase _db;

  /// Optional — null skips all vector writes + vector search. Phase 4
  /// tests follow the same "nullable index" pattern; callers that
  /// don't care about similarity-based retrieval can omit it.
  final MemoryVectorIndex? _vectorIndex;

  final math.Random _rand;

  /// Generate a UUIDv4-ish id. We don't pull in a uuid dep — this is
  /// only used for memory ids and the collision risk at the store's
  /// scale (~thousands of rows) is negligible.
  MemoryId newId() {
    String hex(int len) {
      final buf = StringBuffer();
      for (var i = 0; i < len; i++) {
        buf.write(_rand.nextInt(16).toRadixString(16));
      }
      return buf.toString();
    }

    return MemoryId(
      '${hex(8)}-${hex(4)}-4${hex(3)}-'
      '${(8 + _rand.nextInt(4)).toRadixString(16)}${hex(3)}-${hex(12)}',
    );
  }

  /// Persist a new memory atomically: insert into `memories`, write
  /// join rows, embed + index, then write back the `objectbox_id`.
  ///
  /// Pass the embedding explicitly so the caller (consolidator) can
  /// reuse an embedding it already computed during the
  /// similarity-prefilter step — avoiding a second round-trip through
  /// the embedder.
  Future<Result<Memory, AppError>> save(
    Memory memory, {
    Float32List? embedding,
  }) async {
    try {
      await _db.transaction(() async {
        await _db.into(_db.memories).insertOnConflictUpdate(
              _toCompanion(memory),
            );
        for (final chunkId in memory.sourceChunkIds) {
          await _db.into(_db.memorySources).insertOnConflictUpdate(
                MemorySourcesCompanion(
                  memoryId: Value(memory.id.raw),
                  chunkId: Value(chunkId),
                  weight: const Value(1.0),
                ),
              );
        }
        for (final entityId in memory.entityIds) {
          await _db.into(_db.memoryEntities).insertOnConflictUpdate(
                MemoryEntitiesCompanion(
                  memoryId: Value(memory.id.raw),
                  entityId: Value(entityId),
                ),
              );
        }
      });

      // Vectors live outside the Drift tx — same rationale as
      // VoiceLogRepository.ingest. A mid-crash here leaves a memory
      // row with `objectbox_id = 0`; orphan cleanup reconciles on
      // next startup.
      final index = _vectorIndex;
      if (index != null && embedding != null) {
        final vId = index.put(
          memoryId: memory.id.raw,
          embedding: embedding,
        );
        await (_db.update(_db.memories)
              ..where((m) => m.id.equals(memory.id.raw)))
            .write(MemoriesCompanion(objectboxId: Value(vId)));
      }

      // Re-read so the returned Memory has the authoritative objectbox
      // id and any server-side defaults. Single-row lookup is cheap.
      final reloaded = await _loadOne(memory.id);
      if (reloaded == null) {
        return Err<Memory, AppError>(
          StorageError('memory ${memory.id.raw} vanished after save'),
        );
      }
      return Ok<Memory, AppError>(reloaded);
    } on Object catch (e, st) {
      return Err<Memory, AppError>(
        StorageError('memory save failed', cause: e, stackTrace: st),
      );
    }
  }

  /// Fetch a single memory by id, with provenance + entity ids
  /// populated. Returns `Ok(null)` on unknown id.
  Future<Result<Memory?, AppError>> get(MemoryId id) async {
    try {
      return Ok<Memory?, AppError>(await _loadOne(id));
    } on Object catch (e, st) {
      return Err<Memory?, AppError>(
        StorageError('memory get failed', cause: e, stackTrace: st),
      );
    }
  }

  /// List memories, defaulting to active only — archived/superseded
  /// entries are filtered out so retrieval consumers don't have to
  /// remember the default case.
  Future<Result<List<Memory>, AppError>> list({
    MemoryKind? kind,
    MemoryStatus? status = MemoryStatus.active,
    DateTime? from,
    DateTime? to,
    int limit = 50,
    double minConfidence = kMemoryListMinConfidence,
  }) async {
    try {
      final query = _db.select(_db.memories)
        ..orderBy([
          (m) => OrderingTerm.desc(m.updatedAt),
          (m) => OrderingTerm.asc(m.id),
        ])
        ..limit(limit);
      if (kind != null) {
        query.where((m) => m.kind.equals(_kindName(kind)));
      }
      if (status != null) {
        query.where((m) => m.status.equals(_statusName(status)));
      }
      if (from != null) {
        query.where((m) =>
            m.createdAt.isBiggerOrEqualValue(from.millisecondsSinceEpoch));
      }
      if (to != null) {
        query.where((m) =>
            m.createdAt.isSmallerOrEqualValue(to.millisecondsSinceEpoch));
      }
      if (minConfidence > 0.0) {
        query.where((m) => m.confidence.isBiggerOrEqualValue(minConfidence));
      }
      final rows = await query.get();
      final out = <Memory>[];
      for (final row in rows) {
        final hydrated = await _hydrate(row);
        out.add(hydrated);
      }
      return Ok<List<Memory>, AppError>(out);
    } on Object catch (e, st) {
      return Err<List<Memory>, AppError>(
        StorageError('memory list failed', cause: e, stackTrace: st),
      );
    }
  }

  /// Fetch memories by id in the order provided. Unknown ids are
  /// silently skipped (the caller preserved them from a stale query).
  Future<Result<List<Memory>, AppError>> getMany(List<MemoryId> ids) async {
    if (ids.isEmpty) {
      return const Ok<List<Memory>, AppError>(<Memory>[]);
    }
    try {
      final raws = ids.map((i) => i.raw).toList(growable: false);
      final rows = await (_db.select(_db.memories)
            ..where((m) => m.id.isIn(raws)))
          .get();
      final byId = <String, MemoryRow>{for (final r in rows) r.id: r};
      final out = <Memory>[];
      for (final id in ids) {
        final row = byId[id.raw];
        if (row == null) continue;
        out.add(await _hydrate(row));
      }
      return Ok<List<Memory>, AppError>(out);
    } on Object catch (e, st) {
      return Err<List<Memory>, AppError>(
        StorageError('memory getMany failed', cause: e, stackTrace: st),
      );
    }
  }

  /// Replace a memory's core content atomically. Sources + entity
  /// links are reconciled as a diff (added / removed). Re-embed via
  /// the caller when title/content changed — pass a fresh [embedding].
  Future<Result<Memory, AppError>> update(
    Memory memory, {
    Float32List? embedding,
  }) async {
    try {
      await _db.transaction(() async {
        await (_db.update(_db.memories)
              ..where((m) => m.id.equals(memory.id.raw)))
            .write(_toCompanion(memory));
        // Reconcile join rows as a full replace — simpler than diff,
        // tx-safe, and the join cardinality is small.
        await (_db.delete(_db.memorySources)
              ..where((s) => s.memoryId.equals(memory.id.raw)))
            .go();
        await (_db.delete(_db.memoryEntities)
              ..where((s) => s.memoryId.equals(memory.id.raw)))
            .go();
        for (final chunkId in memory.sourceChunkIds) {
          await _db.into(_db.memorySources).insert(
                MemorySourcesCompanion(
                  memoryId: Value(memory.id.raw),
                  chunkId: Value(chunkId),
                ),
              );
        }
        for (final entityId in memory.entityIds) {
          await _db.into(_db.memoryEntities).insert(
                MemoryEntitiesCompanion(
                  memoryId: Value(memory.id.raw),
                  entityId: Value(entityId),
                ),
              );
        }
      });

      final index = _vectorIndex;
      if (index != null && embedding != null) {
        index.removeByMemoryId(memory.id.raw);
        final vId = index.put(
          memoryId: memory.id.raw,
          embedding: embedding,
        );
        await (_db.update(_db.memories)
              ..where((m) => m.id.equals(memory.id.raw)))
            .write(MemoriesCompanion(objectboxId: Value(vId)));
      }

      final reloaded = await _loadOne(memory.id);
      if (reloaded == null) {
        return Err<Memory, AppError>(
          StorageError('memory ${memory.id.raw} missing after update'),
        );
      }
      return Ok<Memory, AppError>(reloaded);
    } on Object catch (e, st) {
      return Err<Memory, AppError>(
        StorageError('memory update failed', cause: e, stackTrace: st),
      );
    }
  }

  /// Mark [old] superseded by [replacement]. Both rows must already
  /// exist. Vector for [old] is removed so it no longer surfaces in
  /// similarity search (supersededById alone would still rank it).
  Future<Result<void, AppError>> supersede({
    required MemoryId old,
    required MemoryId replacement,
    DateTime? now,
  }) async {
    final ts = (now ?? DateTime.now()).millisecondsSinceEpoch;
    try {
      await _db.transaction(() async {
        await (_db.update(_db.memories)
              ..where((m) => m.id.equals(old.raw)))
            .write(MemoriesCompanion(
          status: const Value('superseded'),
          supersededById: Value(replacement.raw),
          updatedAt: Value(ts),
        ));
      });
      _vectorIndex?.removeByMemoryId(old.raw);
      return const Ok<void, AppError>(null);
    } on Object catch (e, st) {
      return Err<void, AppError>(
        StorageError('memory supersede failed', cause: e, stackTrace: st),
      );
    }
  }

  /// Soft-delete — mark archived. Vector removed; row retained for
  /// provenance + as negative signal for future extraction prompts.
  Future<Result<void, AppError>> archive(MemoryId id, {DateTime? now}) async {
    final ts = (now ?? DateTime.now()).millisecondsSinceEpoch;
    try {
      await (_db.update(_db.memories)
            ..where((m) => m.id.equals(id.raw)))
          .write(MemoriesCompanion(
        status: const Value('archived'),
        updatedAt: Value(ts),
      ));
      _vectorIndex?.removeByMemoryId(id.raw);
      return const Ok<void, AppError>(null);
    } on Object catch (e, st) {
      return Err<void, AppError>(
        StorageError('memory archive failed', cause: e, stackTrace: st),
      );
    }
  }

  /// Hard-delete: vector → drift rows → join rows. Used by "forget
  /// this memory" UX and by test cleanup. Provenance is lost.
  Future<Result<void, AppError>> delete(MemoryId id) async {
    try {
      _vectorIndex?.removeByMemoryId(id.raw);
      await _db.transaction(() async {
        await (_db.delete(_db.memorySources)
              ..where((s) => s.memoryId.equals(id.raw)))
            .go();
        await (_db.delete(_db.memoryEntities)
              ..where((s) => s.memoryId.equals(id.raw)))
            .go();
        await (_db.delete(_db.memories)
              ..where((m) => m.id.equals(id.raw)))
            .go();
      });
      return const Ok<void, AppError>(null);
    } on Object catch (e, st) {
      return Err<void, AppError>(
        StorageError('memory delete failed', cause: e, stackTrace: st),
      );
    }
  }

  /// Remove vectors that no longer have a matching memory row. Same
  /// orphan-reconciliation contract as
  /// [VoiceLogRepository.cleanupOrphanVectors]. Returns the number of
  /// vectors removed.
  Future<Result<int, AppError>> cleanupOrphanVectors() async {
    final index = _vectorIndex;
    if (index == null) return const Ok<int, AppError>(0);
    try {
      final vectorIds = index.allIds();
      if (vectorIds.isEmpty) return const Ok<int, AppError>(0);
      final usedRows = await (_db.selectOnly(_db.memories)
            ..addColumns([_db.memories.objectboxId])
            ..where(_db.memories.objectboxId.isIn(vectorIds)))
          .get();
      final used = <int>{
        for (final r in usedRows) r.read(_db.memories.objectboxId) ?? 0,
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
          'memory cleanupOrphanVectors failed',
          cause: e,
          stackTrace: st,
        ),
      );
    }
  }

  /// Flip the profile cache's stale flag. [ProfileBuilder] checks this
  /// on `current()`.
  Future<Result<void, AppError>> markProfileStale() async {
    try {
      await (_db.update(_db.profileSummaries)
            ..where((p) => p.id.equals(1)))
          .write(const ProfileSummariesCompanion(isStale: Value(1)));
      return const Ok<void, AppError>(null);
    } on Object catch (e, st) {
      return Err<void, AppError>(
        StorageError('markProfileStale failed', cause: e, stackTrace: st),
      );
    }
  }

  /// Write a fresh profile summary. Clears the stale flag.
  Future<Result<void, AppError>> saveProfileSummary({
    required String summary,
    required List<MemoryId> sourceMemoryIds,
    DateTime? updatedAt,
  }) async {
    try {
      final ts = (updatedAt ?? DateTime.now()).millisecondsSinceEpoch;
      await (_db.update(_db.profileSummaries)
            ..where((p) => p.id.equals(1)))
          .write(ProfileSummariesCompanion(
        summary: Value(summary),
        updatedAt: Value(ts),
        sourceMemoryIdsJson:
            Value(jsonEncode(sourceMemoryIds.map((i) => i.raw).toList())),
        isStale: const Value(0),
      ));
      return const Ok<void, AppError>(null);
    } on Object catch (e, st) {
      return Err<void, AppError>(
        StorageError('saveProfileSummary failed', cause: e, stackTrace: st),
      );
    }
  }

  /// Read the cached profile summary row. Always present (seeded on
  /// DB create/migrate), so this returns a record, not nullable.
  Future<Result<ProfileCache, AppError>> loadProfileSummary() async {
    try {
      final row = await (_db.select(_db.profileSummaries)
            ..where((p) => p.id.equals(1)))
          .getSingle();
      final ids = (jsonDecode(row.sourceMemoryIdsJson) as List<dynamic>)
          .cast<String>()
          .map(MemoryId.new)
          .toList(growable: false);
      return Ok<ProfileCache, AppError>(ProfileCache(
        summary: row.summary,
        updatedAt: DateTime.fromMillisecondsSinceEpoch(row.updatedAt),
        sourceMemoryIds: ids,
        isStale: row.isStale != 0,
      ));
    } on Object catch (e, st) {
      return Err<ProfileCache, AppError>(
        StorageError('loadProfileSummary failed', cause: e, stackTrace: st),
      );
    }
  }

  // ─── internals ───────────────────────────────────────────────────

  Future<Memory?> _loadOne(MemoryId id) async {
    final row = await (_db.select(_db.memories)
          ..where((m) => m.id.equals(id.raw)))
        .getSingleOrNull();
    if (row == null) return null;
    return _hydrate(row);
  }

  Future<Memory> _hydrate(MemoryRow row) async {
    final sources = await (_db.select(_db.memorySources)
          ..where((s) => s.memoryId.equals(row.id)))
        .get();
    final entities = await (_db.select(_db.memoryEntities)
          ..where((s) => s.memoryId.equals(row.id)))
        .get();
    final chunkIds = sources.map((s) => s.chunkId).toList(growable: false);
    final entityIds = entities.map((e) => e.entityId).toList(growable: false);
    return _fromRow(row, chunkIds: chunkIds, entityIds: entityIds);
  }

  MemoriesCompanion _toCompanion(Memory m) => MemoriesCompanion(
        id: Value(m.id.raw),
        kind: Value(_kindName(m.kind)),
        title: Value(m.title),
        body: Value(m.content),
        status: Value(_statusName(m.status)),
        confidence: Value(m.confidence),
        createdAt: Value(m.createdAt.millisecondsSinceEpoch),
        updatedAt: Value(m.updatedAt.millisecondsSinceEpoch),
        supersededById: Value(m.supersededById?.raw),
        occurredAt: Value(_occurredAt(m)?.millisecondsSinceEpoch),
        dueAt: Value(_dueAt(m)?.millisecondsSinceEpoch),
        goalState: Value(_goalStateName(m)),
      );

  static DateTime? _occurredAt(Memory m) => switch (m) {
        DecisionMemory() => m.occurredAt,
        EpisodeMemory() => m.occurredAt,
        _ => null,
      };

  static DateTime? _dueAt(Memory m) => switch (m) {
        GoalMemory() => m.dueAt,
        _ => null,
      };

  static String? _goalStateName(Memory m) => switch (m) {
        GoalMemory() => _goalStateToString(m.state),
        _ => null,
      };

  static String _kindName(MemoryKind k) => switch (k) {
        MemoryKind.fact => 'fact',
        MemoryKind.decision => 'decision',
        MemoryKind.episode => 'episode',
        MemoryKind.goal => 'goal',
      };

  static String _statusName(MemoryStatus s) => switch (s) {
        MemoryStatus.active => 'active',
        MemoryStatus.superseded => 'superseded',
        MemoryStatus.resolved => 'resolved',
        MemoryStatus.archived => 'archived',
      };

  static String _goalStateToString(GoalState s) => switch (s) {
        GoalState.open => 'open',
        GoalState.inProgress => 'in_progress',
        GoalState.done => 'done',
        GoalState.abandoned => 'abandoned',
      };

  static MemoryStatus _statusFromString(String s) => switch (s) {
        'active' => MemoryStatus.active,
        'superseded' => MemoryStatus.superseded,
        'resolved' => MemoryStatus.resolved,
        'archived' => MemoryStatus.archived,
        _ => MemoryStatus.active,
      };

  static GoalState _goalStateFromString(String s) => switch (s) {
        'open' => GoalState.open,
        'in_progress' => GoalState.inProgress,
        'done' => GoalState.done,
        'abandoned' => GoalState.abandoned,
        _ => GoalState.open,
      };

  Memory _fromRow(
    MemoryRow row, {
    required List<int> chunkIds,
    required List<int> entityIds,
  }) {
    final id = MemoryId(row.id);
    final status = _statusFromString(row.status);
    final superseded =
        row.supersededById == null ? null : MemoryId(row.supersededById!);
    final createdAt = DateTime.fromMillisecondsSinceEpoch(row.createdAt);
    final updatedAt = DateTime.fromMillisecondsSinceEpoch(row.updatedAt);
    switch (row.kind) {
      case 'decision':
        final occurredMs = row.occurredAt;
        if (occurredMs == null) {
          throw StateError(
            'decision memory ${row.id} missing occurredAt',
          );
        }
        return DecisionMemory(
          id: id,
          title: row.title,
          content: row.body,
          status: status,
          confidence: row.confidence,
          createdAt: createdAt,
          updatedAt: updatedAt,
          supersededById: superseded,
          sourceChunkIds: chunkIds,
          entityIds: entityIds,
          occurredAt: DateTime.fromMillisecondsSinceEpoch(occurredMs),
        );
      case 'episode':
        final occurredMs = row.occurredAt;
        if (occurredMs == null) {
          throw StateError('episode memory ${row.id} missing occurredAt');
        }
        return EpisodeMemory(
          id: id,
          title: row.title,
          content: row.body,
          status: status,
          confidence: row.confidence,
          createdAt: createdAt,
          updatedAt: updatedAt,
          supersededById: superseded,
          sourceChunkIds: chunkIds,
          entityIds: entityIds,
          occurredAt: DateTime.fromMillisecondsSinceEpoch(occurredMs),
        );
      case 'goal':
        final stateStr = row.goalState ?? 'open';
        return GoalMemory(
          id: id,
          title: row.title,
          content: row.body,
          status: status,
          confidence: row.confidence,
          createdAt: createdAt,
          updatedAt: updatedAt,
          supersededById: superseded,
          sourceChunkIds: chunkIds,
          entityIds: entityIds,
          state: _goalStateFromString(stateStr),
          dueAt: row.dueAt == null
              ? null
              : DateTime.fromMillisecondsSinceEpoch(row.dueAt!),
        );
      case 'fact':
      default:
        return FactMemory(
          id: id,
          title: row.title,
          content: row.body,
          status: status,
          confidence: row.confidence,
          createdAt: createdAt,
          updatedAt: updatedAt,
          supersededById: superseded,
          sourceChunkIds: chunkIds,
          entityIds: entityIds,
        );
    }
  }
}

/// Snapshot of the `profile_summaries` singleton row. Pure data —
/// [ProfileBuilder] wraps this in the richer [ProfileSummary] type.
final class ProfileCache {
  const ProfileCache({
    required this.summary,
    required this.updatedAt,
    required this.sourceMemoryIds,
    required this.isStale,
  });

  final String summary;
  final DateTime updatedAt;
  final List<MemoryId> sourceMemoryIds;
  final bool isStale;
}
