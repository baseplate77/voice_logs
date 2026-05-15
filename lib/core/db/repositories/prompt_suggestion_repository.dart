import '../../app_error.dart';
import '../../result.dart';
import '../database.dart';

/// One extracted suggestion chip surfaced in the Ask screen header.
class PromptSuggestionView {
  const PromptSuggestionView({
    required this.id,
    required this.logId,
    required this.chipText,
    required this.question,
    required this.usedCount,
    required this.lastUsedAt,
    required this.createdAt,
  });

  final String id;
  final String logId;
  final String chipText;
  final String question;
  final int usedCount;
  final DateTime? lastUsedAt;
  final DateTime createdAt;

  factory PromptSuggestionView.fromRow(PromptSuggestion row) {
    return PromptSuggestionView(
      id: row.id,
      logId: row.logId,
      chipText: row.chipText,
      question: row.question,
      usedCount: row.usedCount,
      lastUsedAt: row.lastUsedAt == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(row.lastUsedAt!),
      createdAt: DateTime.fromMillisecondsSinceEpoch(row.createdAt),
    );
  }
}

/// A candidate question + chip label produced by the suggestion extraction
/// stage of refine, before any storage shaping. Kept separate from the row
/// type so callers don't need to invent ids or timestamps.
class PromptSuggestionCandidate {
  const PromptSuggestionCandidate({
    required this.chipText,
    required this.question,
  });

  final String chipText;
  final String question;
}

sealed class PromptSuggestionRepositoryError extends AppError {
  const PromptSuggestionRepositoryError({
    required super.message,
    super.cause,
    super.stack,
  });
}

final class PromptSuggestionStorageError
    extends PromptSuggestionRepositoryError {
  const PromptSuggestionStorageError({
    required super.message,
    super.cause,
    super.stack,
  });
}

/// Repository for tap-to-ask suggestion chips. Each log owns 0-4 rows; the
/// selector mixes recent, random-weighted, and top-used candidates when
/// painting the Ask screen header.
class PromptSuggestionRepository {
  PromptSuggestionRepository(this._db);

  final VoxSynthDatabase _db;

  /// Replace every suggestion for [logId]. Re-extraction is idempotent so a
  /// retried refine job doesn't accumulate stale chips.
  Future<Result<List<PromptSuggestionView>, PromptSuggestionRepositoryError>>
  replaceForLog({
    required String logId,
    required List<PromptSuggestionCandidate> candidates,
  }) async {
    try {
      final views = <PromptSuggestionView>[];
      await _db.transaction(() async {
        await (_db.delete(
          _db.promptSuggestions,
        )..where((t) => t.logId.equals(logId))).go();
        final now = DateTime.now().millisecondsSinceEpoch;
        for (var i = 0; i < candidates.length; i++) {
          final c = candidates[i];
          final row = PromptSuggestion(
            id: '${logId}_sg_$i',
            logId: logId,
            chipText: c.chipText,
            question: c.question,
            usedCount: 0,
            createdAt: now,
          );
          await _db.into(_db.promptSuggestions).insert(row);
          views.add(PromptSuggestionView.fromRow(row));
        }
      });
      return Ok(views);
    } on Object catch (e, s) {
      return Err(
        PromptSuggestionStorageError(
          message: 'Failed to replace prompt suggestions: $e',
          cause: e,
          stack: s,
        ),
      );
    }
  }

  /// Increment [usedCount] and stamp [lastUsedAt] when the user taps a chip.
  /// Silent no-op if the row is gone — the chip may have been deleted with
  /// its source log between paint and tap.
  Future<void> bumpUsage(String id) async {
    await _db.customStatement(
      'UPDATE prompt_suggestions SET used_count = used_count + 1, '
      'last_used_at = ? WHERE id = ?',
      [DateTime.now().millisecondsSinceEpoch, id],
    );
  }

  /// All current suggestions across all logs. The selector ranks in Dart so
  /// it can mix recency, randomness, and usage without contorting SQL.
  Future<List<PromptSuggestionView>> all() async {
    final rows = await _db.select(_db.promptSuggestions).get();
    return rows.map(PromptSuggestionView.fromRow).toList(growable: false);
  }

  /// Reactive stream for the Ask screen header. Emits whenever any row is
  /// inserted, deleted, or bumped so chips update live as background refine
  /// finishes new logs in the queue.
  Stream<List<PromptSuggestionView>> watchAll() {
    final query = _db.select(_db.promptSuggestions);
    return query.watch().map(
      (rows) => rows.map(PromptSuggestionView.fromRow).toList(growable: false),
    );
  }
}
