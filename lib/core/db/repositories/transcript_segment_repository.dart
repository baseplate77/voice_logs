import 'package:drift/drift.dart';

import '../../../features/record/speech_recognizer.dart';
import '../../app_error.dart';
import '../../result.dart';
import '../database.dart';

/// UI-facing view of a stored transcript segment with optional per-word
/// timings decoded from the JSON column.
class TranscriptSegmentView {
  const TranscriptSegmentView({
    required this.id,
    required this.logId,
    required this.startMs,
    required this.endMs,
    required this.text,
    required this.words,
  });

  final String id;
  final String logId;
  final int startMs;
  final int endMs;
  final String text;
  final List<WordTiming> words;

  factory TranscriptSegmentView.fromRow(TranscriptSegment row) =>
      TranscriptSegmentView(
        id: row.id,
        logId: row.logId,
        startMs: row.startTimeMs,
        endMs: row.endTimeMs,
        text: row.segmentText,
        words: decodeWordTimings(row.wordTimingsJson),
      );
}

/// Storage errors raised by [TranscriptSegmentRepository].
final class TranscriptSegmentStorageError extends AppError {
  const TranscriptSegmentStorageError({
    required super.message,
    super.cause,
    super.stack,
  });
}

/// Persists STT segment metadata + word timings. Distinct from
/// `VoiceLogSegments` (post-refine embedded chunks) — those serve search;
/// these serve word-level scrubbing of the original audio.
class TranscriptSegmentRepository {
  TranscriptSegmentRepository(this._db);

  final VoxSynthDatabase _db;

  /// Insert every segment of a freshly transcribed log in a single
  /// transaction. Existing rows for [logId] are deleted first so retries
  /// don't leave stale segments behind.
  Future<Result<void, TranscriptSegmentStorageError>> replaceForLog({
    required String logId,
    required List<TranscriptSegmentResult> segments,
  }) async {
    try {
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      await _db.transaction(() async {
        await (_db.delete(
          _db.transcriptSegments,
        )..where((t) => t.logId.equals(logId))).go();
        for (var i = 0; i < segments.length; i++) {
          final s = segments[i];
          await _db
              .into(_db.transcriptSegments)
              .insert(
                TranscriptSegmentsCompanion.insert(
                  id: '${logId}_$i',
                  logId: logId,
                  startTimeMs: s.startMs,
                  endTimeMs: s.endMs,
                  segmentText: s.text,
                  createdAt: nowMs,
                  wordTimingsJson: Value(encodeWordTimings(s.words)),
                ),
              );
        }
      });
      return const Ok(null);
    } on Object catch (e, s) {
      return Err(
        TranscriptSegmentStorageError(
          message: 'Failed to persist transcript segments: $e',
          cause: e,
          stack: s,
        ),
      );
    }
  }

  /// Fetch every segment for a log ordered by start time. Empty list when
  /// the recognizer ran in text-only mode or before this table existed.
  Future<List<TranscriptSegmentView>> findByLogId(String logId) async {
    final query = _db.select(_db.transcriptSegments)
      ..where((t) => t.logId.equals(logId))
      ..orderBy([(t) => OrderingTerm.asc(t.startTimeMs)]);
    final rows = await query.get();
    return rows.map(TranscriptSegmentView.fromRow).toList(growable: false);
  }
}
