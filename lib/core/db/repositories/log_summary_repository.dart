import 'dart:convert';

import 'package:drift/drift.dart';

import '../../app_error.dart';
import '../../result.dart';
import '../database.dart';

/// Read shape returned to callers. Lists are eagerly decoded so widgets can
/// render without re-parsing JSON.
class LogSummaryView {
  const LogSummaryView({
    required this.logId,
    required this.oneLiner,
    required this.bullets,
    required this.peopleProjects,
    required this.decisions,
    required this.followUps,
    required this.modelVersion,
    required this.generatedAt,
  });

  final String logId;
  final String oneLiner;
  final List<String> bullets;
  final List<String> peopleProjects;
  final List<String> decisions;
  final List<String> followUps;
  final String? modelVersion;
  final DateTime generatedAt;
}

/// Input shape produced by [parseSummaryResponse] and persisted by
/// [LogSummaryRepository.upsert]. Kept separate from the row type so the
/// summarize runner doesn't reach into Drift companions.
class LogSummaryWrite {
  const LogSummaryWrite({
    required this.oneLiner,
    required this.bullets,
    required this.peopleProjects,
    required this.decisions,
    required this.followUps,
  });

  final String oneLiner;
  final List<String> bullets;
  final List<String> peopleProjects;
  final List<String> decisions;
  final List<String> followUps;
}

sealed class LogSummaryRepositoryError extends AppError {
  const LogSummaryRepositoryError({
    required super.message,
    super.cause,
    super.stack,
  });
}

final class LogSummaryStorageError extends LogSummaryRepositoryError {
  const LogSummaryStorageError({
    required super.message,
    super.cause,
    super.stack,
  });
}

/// Kind of digest persisted alongside per-log summaries in the polymorphic
/// `summaries` table. Wire values match the `type` column.
enum DigestKind {
  daily('daily'),
  weekly('weekly');

  const DigestKind(this.wire);

  final String wire;
}

/// Read shape for a daily or weekly digest. The five lists are decoded
/// eagerly so widgets can render without re-parsing JSON.
///
/// Field mapping (mirrors [DigestWrite]):
/// - `oneLiner` → `summaries.title`
/// - `bullets`  → `summaries.body` (newline-joined)
/// - `topics`   → `summaries.topics_json`
/// - `actions`  → `summaries.action_items_json`
/// - `decisions`→ `summaries.decisions_json`
/// - `mood`     → `summaries.mood` (daily only; null for weekly)
class DigestView {
  const DigestView({
    required this.kind,
    required this.windowKey,
    required this.oneLiner,
    required this.bullets,
    required this.topics,
    required this.actions,
    required this.decisions,
    required this.mood,
    required this.generatedAt,
  });

  final DigestKind kind;

  /// Stable identifier for the window — yyyy-MM-dd for daily, or the
  /// start-of-week date for weekly.
  final String windowKey;

  final String oneLiner;
  final List<String> bullets;
  final List<String> topics;
  final List<String> actions;
  final List<String> decisions;
  final String? mood;
  final DateTime generatedAt;
}

/// Input shape produced by `parseDigestResponse` and persisted by
/// [LogSummaryRepository.upsertDigest]. Field semantics depend on
/// [DigestKind]:
///
/// **Daily** — `bullets` = what happened, `topics` = people mentioned,
/// `actions` = tasks created, `decisions` = decisions, `mood` = mood/theme.
///
/// **Weekly** — `bullets` = main themes, `topics` = project progress notes,
/// `actions` = unfinished tasks, `decisions` = repeated concerns,
/// `mood` always null.
class DigestWrite {
  const DigestWrite({
    required this.oneLiner,
    required this.bullets,
    required this.topics,
    required this.actions,
    required this.decisions,
    this.mood,
  });

  final String oneLiner;
  final List<String> bullets;
  final List<String> topics;
  final List<String> actions;
  final List<String> decisions;
  final String? mood;
}

/// Per-log summary persistence backed by the polymorphic `summaries` table.
/// Rows live under `type = 'log'` with `source_id = <voice_log_id>` and a
/// deterministic id so re-running the summarize job replaces in place.
///
/// The same repository also persists digest rows under `type = 'daily'` /
/// `type = 'weekly'`, keyed on a window string (see [DigestKind]).
class LogSummaryRepository {
  LogSummaryRepository(this._db);

  final VoxSynthDatabase _db;

  static const String _typeLog = 'log';

  String _rowId(String logId) => '$_typeLog:$logId';

  String _digestRowId(DigestKind kind, String windowKey) =>
      '${kind.wire}:$windowKey';

  Future<Result<LogSummaryView, LogSummaryRepositoryError>> upsert({
    required String logId,
    required LogSummaryWrite write,
    String? modelVersion,
  }) async {
    try {
      final now = DateTime.now().millisecondsSinceEpoch;
      final id = _rowId(logId);
      final existing = await (_db.select(
        _db.summaries,
      )..where((t) => t.id.equals(id))).getSingleOrNull();
      final createdAt = existing?.createdAt ?? now;

      final companion = SummariesCompanion(
        id: Value(id),
        type: const Value(_typeLog),
        sourceId: Value(logId),
        title: Value(write.oneLiner),
        body: Value(write.bullets.join('\n')),
        topicsJson: Value(jsonEncode(write.peopleProjects)),
        actionItemsJson: Value(jsonEncode(write.followUps)),
        decisionsJson: Value(jsonEncode(write.decisions)),
        sourceChunkIdsJson: const Value('[]'),
        stale: const Value(0),
        generatedAt: Value(now),
        createdAt: Value(createdAt),
        updatedAt: Value(now),
      );
      await _db
          .into(_db.summaries)
          .insert(companion, mode: InsertMode.insertOrReplace);

      return Ok(
        LogSummaryView(
          logId: logId,
          oneLiner: write.oneLiner,
          bullets: List<String>.unmodifiable(write.bullets),
          peopleProjects: List<String>.unmodifiable(write.peopleProjects),
          decisions: List<String>.unmodifiable(write.decisions),
          followUps: List<String>.unmodifiable(write.followUps),
          modelVersion: modelVersion,
          generatedAt: DateTime.fromMillisecondsSinceEpoch(now),
        ),
      );
    } on Object catch (e, s) {
      return Err(
        LogSummaryStorageError(
          message: 'Failed to upsert log summary: $e',
          cause: e,
          stack: s,
        ),
      );
    }
  }

  Future<LogSummaryView?> findByLogId(String logId) async {
    final row = await (_db.select(
      _db.summaries,
    )..where((t) => t.id.equals(_rowId(logId)))).getSingleOrNull();
    if (row == null) return null;
    return _viewFromRow(row);
  }

  Stream<LogSummaryView?> watchByLogId(String logId) {
    final query = _db.select(_db.summaries)
      ..where((t) => t.id.equals(_rowId(logId)));
    return query.watchSingleOrNull().map(
      (row) => row == null ? null : _viewFromRow(row),
    );
  }

  Future<Result<void, LogSummaryRepositoryError>> deleteForLog(
    String logId,
  ) async {
    try {
      await (_db.delete(
        _db.summaries,
      )..where((t) => t.id.equals(_rowId(logId)))).go();
      return const Ok(null);
    } on Object catch (e, s) {
      return Err(
        LogSummaryStorageError(
          message: 'Failed to delete log summary: $e',
          cause: e,
          stack: s,
        ),
      );
    }
  }

  /// Persist a digest row. Replaces any existing row for the same
  /// `(kind, windowKey)` pair, matching the upsert semantics used for
  /// per-log summaries.
  Future<Result<DigestView, LogSummaryRepositoryError>> upsertDigest({
    required DigestKind kind,
    required String windowKey,
    required DigestWrite write,
  }) async {
    try {
      final now = DateTime.now().millisecondsSinceEpoch;
      final id = _digestRowId(kind, windowKey);
      final existing = await (_db.select(
        _db.summaries,
      )..where((t) => t.id.equals(id))).getSingleOrNull();
      final createdAt = existing?.createdAt ?? now;

      final companion = SummariesCompanion(
        id: Value(id),
        type: Value(kind.wire),
        sourceId: Value(windowKey),
        title: Value(write.oneLiner),
        body: Value(write.bullets.join('\n')),
        topicsJson: Value(jsonEncode(write.topics)),
        actionItemsJson: Value(jsonEncode(write.actions)),
        decisionsJson: Value(jsonEncode(write.decisions)),
        mood: Value(write.mood),
        sourceChunkIdsJson: const Value('[]'),
        stale: const Value(0),
        generatedAt: Value(now),
        createdAt: Value(createdAt),
        updatedAt: Value(now),
      );
      await _db
          .into(_db.summaries)
          .insert(companion, mode: InsertMode.insertOrReplace);

      return Ok(
        DigestView(
          kind: kind,
          windowKey: windowKey,
          oneLiner: write.oneLiner,
          bullets: List<String>.unmodifiable(write.bullets),
          topics: List<String>.unmodifiable(write.topics),
          actions: List<String>.unmodifiable(write.actions),
          decisions: List<String>.unmodifiable(write.decisions),
          mood: write.mood,
          generatedAt: DateTime.fromMillisecondsSinceEpoch(now),
        ),
      );
    } on Object catch (e, s) {
      return Err(
        LogSummaryStorageError(
          message: 'Failed to upsert digest: $e',
          cause: e,
          stack: s,
        ),
      );
    }
  }

  /// One-shot lookup for a digest by window. Returns null when no row has
  /// been generated for the requested window yet.
  Future<DigestView?> findDigest({
    required DigestKind kind,
    required String windowKey,
  }) async {
    final row =
        await (_db.select(_db.summaries)
              ..where((t) => t.id.equals(_digestRowId(kind, windowKey))))
            .getSingleOrNull();
    if (row == null) return null;
    return _digestFromRow(row, kind);
  }

  /// Reactive lookup for a digest by window. The digest screen subscribes
  /// to this so it can swap a spinner for the card the moment the job
  /// writes the row.
  Stream<DigestView?> watchDigest({
    required DigestKind kind,
    required String windowKey,
  }) {
    final query = _db.select(_db.summaries)
      ..where((t) => t.id.equals(_digestRowId(kind, windowKey)));
    return query.watchSingleOrNull().map(
      (row) => row == null ? null : _digestFromRow(row, kind),
    );
  }

  DigestView _digestFromRow(Summary row, DigestKind kind) {
    return DigestView(
      kind: kind,
      windowKey: row.sourceId,
      oneLiner: row.title,
      bullets: _splitBullets(row.body),
      topics: _decodeStringList(row.topicsJson),
      actions: _decodeStringList(row.actionItemsJson),
      decisions: _decodeStringList(row.decisionsJson),
      mood: row.mood,
      generatedAt: DateTime.fromMillisecondsSinceEpoch(row.generatedAt),
    );
  }

  LogSummaryView _viewFromRow(Summary row) {
    return LogSummaryView(
      logId: row.sourceId,
      oneLiner: row.title,
      bullets: _splitBullets(row.body),
      peopleProjects: _decodeStringList(row.topicsJson),
      decisions: _decodeStringList(row.decisionsJson),
      followUps: _decodeStringList(row.actionItemsJson),
      modelVersion: null,
      generatedAt: DateTime.fromMillisecondsSinceEpoch(row.generatedAt),
    );
  }
}

List<String> _splitBullets(String body) {
  if (body.isEmpty) return const <String>[];
  return body
      .split('\n')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList(growable: false);
}

List<String> _decodeStringList(String? json) {
  if (json == null || json.isEmpty) return const <String>[];
  try {
    final decoded = jsonDecode(json);
    if (decoded is! List) return const <String>[];
    return decoded
        .whereType<String>()
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList(growable: false);
  } on FormatException {
    return const <String>[];
  }
}
