import 'package:meta/meta.dart';

import '../../llm/models/cleaned_transcript.dart';

/// Strongly-typed VoiceLog id — distinct from an arbitrary String so
/// downstream code can't swap one for a Chunk id.
extension type const VoiceLogId(String raw) {}

/// Public view of a persisted voice log. Wraps the Drift row with
/// pre-parsed chunk + entity lists so callers don't have to round-trip
/// to the store for those.
@immutable
final class VoiceLogRecord {
  const VoiceLogRecord({
    required this.id,
    required this.startedAt,
    required this.durationMs,
    required this.audioPath,
    required this.language,
    required this.cleanedTranscript,
    required this.rawTranscript,
    required this.sourceTag,
    required this.chunks,
    required this.entities,
  });

  final VoiceLogId id;
  final DateTime startedAt;
  final int durationMs;
  final String audioPath;
  final String language;
  final String cleanedTranscript;
  final String? rawTranscript;
  final String? sourceTag;
  final List<ChunkRecord> chunks;
  final List<Entity> entities;

  @override
  String toString() =>
      'VoiceLogRecord(${id.raw}, $durationMs ms, ${chunks.length} chunks)';
}

/// Public view of a persisted chunk. Carries the surrounding log id +
/// ObjectBox vector id so Phase 5 retrieval can correlate without a
/// re-query.
@immutable
final class ChunkRecord {
  const ChunkRecord({
    required this.id,
    required this.logId,
    required this.text,
    required this.startChar,
    required this.endChar,
    required this.topicHint,
    required this.createdAt,
    required this.objectboxId,
    this.topicClusterId,
  });

  final int id;
  final VoiceLogId logId;
  final String text;
  final int startChar;
  final int endChar;
  final String topicHint;
  final DateTime createdAt;

  /// 0 = no vector stored yet. Phase 4c populates this on ingest once
  /// the ObjectBox index is live.
  final int objectboxId;

  /// Null until Phase 7's weekly clusterer runs.
  final int? topicClusterId;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ChunkRecord &&
          other.id == id &&
          other.logId == logId &&
          other.text == text &&
          other.startChar == startChar &&
          other.endChar == endChar &&
          other.topicHint == topicHint &&
          other.createdAt == createdAt &&
          other.objectboxId == objectboxId &&
          other.topicClusterId == topicClusterId);

  @override
  int get hashCode => Object.hash(
        id,
        logId,
        text,
        startChar,
        endChar,
        topicHint,
        createdAt,
        objectboxId,
        topicClusterId,
      );

  @override
  String toString() =>
      'ChunkRecord(#$id, ${text.length} chars, "$topicHint")';
}
