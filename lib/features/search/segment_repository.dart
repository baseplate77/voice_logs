import 'dart:typed_data';

import '../../core/app_error.dart';
import '../../core/db/database.dart';
import '../../core/result.dart';
import 'embedder.dart';
import 'segmenter.dart';

/// One persisted segment, ready to be loaded into [VecStore].
class StoredSegment {
  const StoredSegment({
    required this.id,
    required this.logId,
    required this.index,
    required this.text,
    required this.embedding,
  });

  final String id;
  final String logId;
  final int index;
  final String text;
  final Float32List embedding;
}

/// Errors from the segment storage layer.
sealed class SegmentStorageError extends AppError {
  const SegmentStorageError({required super.message, super.cause, super.stack});
}

final class SegmentStorageDbError extends SegmentStorageError {
  const SegmentStorageDbError({
    required super.message,
    super.cause,
    super.stack,
  });
}

/// Persists segment text + L2-normalized embeddings against a voice log.
class SegmentRepository {
  SegmentRepository(this._db);

  final VoxSynthDatabase _db;

  /// Insert all [segments], one row per embedding. Paired lists must
  /// have the same length. Pre-existing segments for the log are
  /// cleared first (re-embedding is idempotent).
  Future<Result<void, SegmentStorageError>> upsert({
    required String logId,
    required List<TextSegment> segments,
    required List<Embedding> embeddings,
  }) async {
    if (segments.length != embeddings.length) {
      return const Err(
        SegmentStorageDbError(
          message: 'segments and embeddings lengths must match',
        ),
      );
    }
    try {
      await _db.transaction(() async {
        await (_db.delete(
          _db.voiceLogSegments,
        )..where((t) => t.logId.equals(logId))).go();
        for (var i = 0; i < segments.length; i++) {
          final seg = segments[i];
          final blob = _floatsToBytes(embeddings[i].vector);
          await _db
              .into(_db.voiceLogSegments)
              .insert(
                VoiceLogSegment(
                  id: '${logId}_seg_${seg.index}',
                  logId: logId,
                  segmentIndex: seg.index,
                  segmentText: seg.text,
                  embedding: blob,
                ),
              );
        }
      });
      return const Ok(null);
    } on Object catch (e, s) {
      return Err(
        SegmentStorageDbError(
          message: 'Failed to upsert segments: $e',
          cause: e,
          stack: s,
        ),
      );
    }
  }

  /// Load every segment in the database. Called once on app start to
  /// warm the in-memory [VecStore]; subsequent inserts update both the
  /// DB and the store.
  Future<List<StoredSegment>> all() async {
    final rows = await _db.select(_db.voiceLogSegments).get();
    return rows
        .map(
          (r) => StoredSegment(
            id: r.id,
            logId: r.logId,
            index: r.segmentIndex,
            text: r.segmentText,
            embedding: _bytesToFloats(r.embedding),
          ),
        )
        .toList();
  }

  Future<void> deleteForLog(String logId) async {
    await (_db.delete(
      _db.voiceLogSegments,
    )..where((t) => t.logId.equals(logId))).go();
  }

  static Uint8List _floatsToBytes(Float32List floats) =>
      floats.buffer.asUint8List(floats.offsetInBytes, floats.lengthInBytes);

  static Float32List _bytesToFloats(Uint8List bytes) {
    // Copy the bytes into an aligned buffer before reinterpreting — the
    // original buffer may be a slice with an offset that doesn't suit a
    // Float32List view.
    final aligned = Uint8List.fromList(bytes);
    return aligned.buffer.asFloat32List();
  }
}
