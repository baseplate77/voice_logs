import 'dart:convert';

import 'package:drift/drift.dart';

import '../../../features/ask/ask_chat_message.dart';
import '../../../features/memory/memory_types.dart';
import '../../../features/search/hybrid_retriever.dart';
import '../../app_error.dart';
import '../../result.dart';
import '../database.dart';

/// Lightweight thread view for the Ask Journal history sheet.
class AskThreadView {
  const AskThreadView({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String title;
  final DateTime createdAt;
  final DateTime updatedAt;

  factory AskThreadView.fromRow(AskThread row) {
    return AskThreadView(
      id: row.id,
      title: row.title,
      createdAt: DateTime.fromMillisecondsSinceEpoch(row.createdAt),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(row.updatedAt),
    );
  }
}

sealed class AskChatRepositoryError extends AppError {
  const AskChatRepositoryError({
    required super.message,
    super.cause,
    super.stack,
  });
}

final class AskChatStorageError extends AskChatRepositoryError {
  const AskChatStorageError({required super.message, super.cause, super.stack});
}

/// Persists Ask Journal threads and message/source snapshots locally.
class AskChatRepository {
  AskChatRepository(this._db);

  final VoxSynthDatabase _db;

  Stream<List<AskThreadView>> watchThreads() {
    final query = _db.select(_db.askThreads)
      ..orderBy([(t) => OrderingTerm.desc(t.updatedAt)]);
    return query.watch().map(
      (rows) => rows.map(AskThreadView.fromRow).toList(),
    );
  }

  Future<AskThreadView?> latestThread() async {
    final row =
        await (_db.select(_db.askThreads)
              ..orderBy([(t) => OrderingTerm.desc(t.updatedAt)])
              ..limit(1))
            .getSingleOrNull();
    return row == null ? null : AskThreadView.fromRow(row);
  }

  Future<Result<AskThreadView, AskChatStorageError>> createThread({
    String? title,
    DateTime? now,
  }) async {
    try {
      final created = now ?? DateTime.now();
      final id = 'ask_${created.microsecondsSinceEpoch}';
      final row = AskThread(
        id: id,
        title: _threadTitle(title),
        createdAt: created.millisecondsSinceEpoch,
        updatedAt: created.millisecondsSinceEpoch,
      );
      await _db.into(_db.askThreads).insert(row);
      return Ok(AskThreadView.fromRow(row));
    } on Object catch (e, s) {
      return Err(
        AskChatStorageError(
          message: 'Failed to create Ask thread: $e',
          cause: e,
          stack: s,
        ),
      );
    }
  }

  Future<Result<void, AskChatStorageError>> renameThread({
    required String threadId,
    required String title,
  }) async {
    try {
      await (_db.update(
        _db.askThreads,
      )..where((t) => t.id.equals(threadId))).write(
        AskThreadsCompanion(
          title: Value(_threadTitle(title)),
          updatedAt: Value(DateTime.now().millisecondsSinceEpoch),
        ),
      );
      return const Ok(null);
    } on Object catch (e, s) {
      return Err(
        AskChatStorageError(
          message: 'Failed to rename Ask thread: $e',
          cause: e,
          stack: s,
        ),
      );
    }
  }

  Future<Result<void, AskChatStorageError>> deleteThread(
    String threadId,
  ) async {
    try {
      await _db.transaction(() async {
        await (_db.delete(
          _db.askMessages,
        )..where((t) => t.threadId.equals(threadId))).go();
        await (_db.delete(
          _db.askThreads,
        )..where((t) => t.id.equals(threadId))).go();
      });
      return const Ok(null);
    } on Object catch (e, s) {
      return Err(
        AskChatStorageError(
          message: 'Failed to delete Ask thread: $e',
          cause: e,
          stack: s,
        ),
      );
    }
  }

  Future<List<AskChatMessage>> messagesForThread(String threadId) async {
    // Tied createdAt timestamps are routine: the user message and the
    // assistant placeholder are inserted microseconds apart and frequently
    // share the same millisecond. SQLite would otherwise return them in
    // arbitrary order on reload, flipping the conversation. The implicit
    // rowid is monotonically increasing on insert, so it's the right
    // secondary sort.
    final rows = await _db
        .customSelect(
          'SELECT * FROM ask_messages WHERE thread_id = ? '
          'ORDER BY created_at ASC, rowid ASC',
          variables: [Variable<String>(threadId)],
          readsFrom: {_db.askMessages},
        )
        .map((row) => _db.askMessages.map(row.data))
        .get();
    return rows.map(_messageFromRow).toList(growable: false);
  }

  Future<Result<void, AskChatStorageError>> saveMessage({
    required String threadId,
    required AskChatMessage message,
  }) async {
    try {
      final now = DateTime.now().millisecondsSinceEpoch;
      await _db
          .into(_db.askMessages)
          .insertOnConflictUpdate(
            AskMessagesCompanion.insert(
              id: message.id,
              threadId: threadId,
              role: message.role.name,
              messageText: message.text,
              logHitsJson: Value(_encodeLogHits(message.logHits)),
              memoryHitsJson: Value(_encodeMemoryHits(message.memoryHits)),
              streaming: Value(message.streaming ? 1 : 0),
              createdAt: now,
              updatedAt: now,
            ),
          );
      await _touchThread(threadId);
      return const Ok(null);
    } on Object catch (e, s) {
      return Err(
        AskChatStorageError(
          message: 'Failed to save Ask message: $e',
          cause: e,
          stack: s,
        ),
      );
    }
  }

  Future<Result<void, AskChatStorageError>> updateMessage({
    required String threadId,
    required AskChatMessage message,
  }) async {
    try {
      await (_db.update(
        _db.askMessages,
      )..where((t) => t.id.equals(message.id))).write(
        AskMessagesCompanion(
          messageText: Value(message.text),
          logHitsJson: Value(_encodeLogHits(message.logHits)),
          memoryHitsJson: Value(_encodeMemoryHits(message.memoryHits)),
          streaming: Value(message.streaming ? 1 : 0),
          updatedAt: Value(DateTime.now().millisecondsSinceEpoch),
        ),
      );
      await _touchThread(threadId);
      return const Ok(null);
    } on Object catch (e, s) {
      return Err(
        AskChatStorageError(
          message: 'Failed to update Ask message: $e',
          cause: e,
          stack: s,
        ),
      );
    }
  }

  Future<void> _touchThread(String threadId) async {
    await (_db.update(
      _db.askThreads,
    )..where((t) => t.id.equals(threadId))).write(
      AskThreadsCompanion(
        updatedAt: Value(DateTime.now().millisecondsSinceEpoch),
      ),
    );
  }

  AskChatMessage _messageFromRow(AskMessage row) {
    final role = row.role == AskChatRole.assistant.name
        ? AskChatRole.assistant
        : AskChatRole.user;
    return AskChatMessage(
      id: row.id,
      role: role,
      text: row.messageText,
      streaming: false,
      logHits: _decodeLogHits(row.logHitsJson),
      memoryHits: _decodeMemoryHits(row.memoryHitsJson),
    );
  }

  String? _encodeLogHits(List<SearchHit> hits) {
    if (hits.isEmpty) return null;
    return jsonEncode([
      for (final hit in hits)
        {
          'log_id': hit.logId,
          'score': hit.fusedScore,
          'matched_via': hit.matchedVia.map((s) => s.name).toList(),
          'snippet': hit.snippet,
          'segments': hit.segments,
          'full_text': hit.fullText,
          'created_at': hit.createdAt?.millisecondsSinceEpoch,
          'log_title': hit.logTitle,
          'best_segment_id': hit.bestSegmentId,
          'best_start_ms': hit.bestSegmentStartMs,
          'best_end_ms': hit.bestSegmentEndMs,
          'local_reason': hit.localReason,
          'entity_names': hit.matchedEntityNames,
        },
    ]);
  }

  List<SearchHit> _decodeLogHits(String? json) {
    if (json == null || json.trim().isEmpty) return const [];
    try {
      final raw = jsonDecode(json);
      if (raw is! List) return const [];
      return raw
          .whereType<Map<dynamic, dynamic>>()
          .map((m) {
            final map = m.cast<String, Object?>();
            final createdAt = map['created_at'];
            return SearchHit(
              logId: map['log_id'] as String? ?? '',
              fusedScore: (map['score'] as num?)?.toDouble() ?? 0,
              matchedVia: _decodeMatchSources(map['matched_via']),
              snippet: map['snippet'] as String? ?? '',
              segments: _stringList(map['segments']),
              fullText: map['full_text'] as String?,
              createdAt: createdAt is int
                  ? DateTime.fromMillisecondsSinceEpoch(createdAt)
                  : null,
              logTitle: map['log_title'] as String?,
              bestSegmentId: map['best_segment_id'] as String?,
              bestSegmentStartMs: map['best_start_ms'] as int?,
              bestSegmentEndMs: map['best_end_ms'] as int?,
              localReason: map['local_reason'] as String? ?? '',
              matchedEntityNames: _stringList(map['entity_names']),
            );
          })
          .toList(growable: false);
    } on Object {
      return const [];
    }
  }

  Set<MatchSource> _decodeMatchSources(Object? raw) {
    final names = _stringList(raw);
    return {
      for (final name in names)
        for (final source in MatchSource.values)
          if (source.name == name) source,
    };
  }

  String? _encodeMemoryHits(List<MemoryHit> hits) {
    if (hits.isEmpty) return null;
    return jsonEncode([
      for (final hit in hits)
        {
          'id': hit.memory.id,
          'type': hit.memory.type.wire,
          'text': hit.memory.text,
          'normalized_text': hit.memory.normalizedText,
          'confidence': hit.memory.confidence,
          'status': hit.memory.status.wire,
          'sensitivity': hit.memory.sensitivity.wire,
          'first_seen_at': hit.memory.firstSeenAt.millisecondsSinceEpoch,
          'last_seen_at': hit.memory.lastSeenAt.millisecondsSinceEpoch,
          'created_at': hit.memory.createdAt.millisecondsSinceEpoch,
          'updated_at': hit.memory.updatedAt.millisecondsSinceEpoch,
          'importance_score': hit.memory.importanceScore,
          'score': hit.fusedScore,
          'matched_via': hit.matchedVia.map((s) => s.name).toList(),
        },
    ]);
  }

  List<MemoryHit> _decodeMemoryHits(String? json) {
    if (json == null || json.trim().isEmpty) return const [];
    try {
      final raw = jsonDecode(json);
      if (raw is! List) return const [];
      return raw
          .whereType<Map<dynamic, dynamic>>()
          .map((m) {
            final map = m.cast<String, Object?>();
            final now = DateTime.now();
            return MemoryHit(
              memory: MemoryItemView(
                id: map['id'] as String? ?? '',
                type:
                    MemoryType.fromWireOrNull(map['type'] as String? ?? '') ??
                    MemoryType.idea,
                text: map['text'] as String? ?? '',
                normalizedText: map['normalized_text'] as String? ?? '',
                confidence: (map['confidence'] as num?)?.toDouble() ?? 0,
                status: MemoryStatus.fromWire(map['status'] as String? ?? ''),
                sensitivity:
                    MemorySensitivity.fromWireOrNull(
                      map['sensitivity'] as String? ?? '',
                    ) ??
                    MemorySensitivity.normal,
                firstSeenAt: _dateOrNow(map['first_seen_at'], now),
                lastSeenAt: _dateOrNow(map['last_seen_at'], now),
                createdAt: _dateOrNow(map['created_at'], now),
                updatedAt: _dateOrNow(map['updated_at'], now),
                embedding: null,
                importanceScore: (map['importance_score'] as num?)?.toDouble(),
              ),
              fusedScore: (map['score'] as num?)?.toDouble() ?? 0,
              matchedVia: _decodeMemorySources(map['matched_via']),
            );
          })
          .toList(growable: false);
    } on Object {
      return const [];
    }
  }

  Set<MemoryMatchSource> _decodeMemorySources(Object? raw) {
    final names = _stringList(raw);
    return {
      for (final name in names)
        for (final source in MemoryMatchSource.values)
          if (source.name == name) source,
    };
  }

  DateTime _dateOrNow(Object? raw, DateTime now) {
    return raw is int ? DateTime.fromMillisecondsSinceEpoch(raw) : now;
  }

  List<String> _stringList(Object? raw) {
    if (raw is! List) return const [];
    return raw.whereType<String>().toList(growable: false);
  }

  String _threadTitle(String? raw) {
    final compact = (raw == null || raw.trim().isEmpty ? 'New chat' : raw)
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    final words = RegExp(r"[A-Za-z0-9]+(?:['’-][A-Za-z0-9]+)?")
        .allMatches(compact)
        .map((m) => m.group(0)!)
        .take(8)
        .toList(growable: false);
    if (words.isEmpty) return 'New chat';
    return words.join(' ');
  }
}
