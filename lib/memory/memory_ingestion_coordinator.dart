import 'package:meta/meta.dart';

import '../asr/models/transcript.dart';
import '../capture/models/speech_segment.dart';
import '../core/errors.dart';
import '../core/logger.dart';
import '../core/result.dart';
import '../llm/models/cleaned_transcript.dart';
import '../store/models/voice_log_record.dart';
import '../store/voice_log_repository.dart';
import 'memory_consolidator.dart';
import 'memory_extractor.dart';
import 'models/consolidation_result.dart';
import 'models/memory.dart';
import 'profile_builder.dart';

/// Summary of one ingest → memory pass. Returned to the caller (UI
/// usually) so it can surface the extracted memory cards for the
/// user to accept/edit/reject.
@immutable
final class IngestionOutcome {
  const IngestionOutcome({
    required this.logId,
    required this.consolidation,
  });

  final VoiceLogId logId;
  final ConsolidationResult consolidation;

  @override
  String toString() =>
      'IngestionOutcome(${logId.raw}, $consolidation)';
}

/// Single entry point for "record → store → remember".
///
/// Replaces direct callers of [VoiceLogRepository.ingest()] that want
/// the memory layer in the loop. Callers that *don't* want memory
/// extraction (e.g. restoring from a backup) can still call
/// `voiceLogRepository.ingest()` directly — the coordinator is
/// strictly additive.
///
/// Flow:
///   1. `voiceLogRepository.ingest(...)` — chunks + entities + vectors.
///   2. On Ok, re-read the log so the extractor sees authoritative
///      chunk ids (chunks are auto-incremented on insert).
///   3. `extractor.extract(cleaned, chunks)` — Gemma → candidates.
///   4. `consolidator.consolidate(candidates)` — dedupe + supersedence.
///   5. On structural change, `profileBuilder.markStale()` so the next
///      query rebuilds the always-on "about me" blurb.
///
/// Steps 3-5 are best-effort — a failure surfaces a warning and the
/// ingest's success is *not* undone. Memory extraction can always be
/// retried against the persisted log later.
class MemoryIngestionCoordinator {
  MemoryIngestionCoordinator({
    required this.voiceLogRepository,
    required this.extractor,
    required this.consolidator,
    required this.profileBuilder,
    AppLogger? logger,
  }) : _logger = logger ?? AppLogger();

  final VoiceLogRepository voiceLogRepository;
  final MemoryExtractor extractor;
  final MemoryConsolidator consolidator;
  final ProfileBuilder profileBuilder;
  final AppLogger _logger;

  /// Ingest a recording and produce memories. The outer `Result` fails
  /// only when the underlying voice-log ingest fails — memory
  /// extraction issues are logged and surfaced as an empty
  /// [ConsolidationResult].
  Future<Result<IngestionOutcome, AppError>> ingest({
    required RecordingHandle recording,
    required Transcript transcript,
    required CleanedTranscript cleaned,
  }) async {
    final ingestR = await voiceLogRepository.ingest(
      recording: recording,
      transcript: transcript,
      cleaned: cleaned,
    );
    if (ingestR.isErr) {
      return Err<IngestionOutcome, AppError>(ingestR.errOrNull!);
    }
    final logId = ingestR.okOrNull!;

    final logR = await voiceLogRepository.getLog(logId);
    if (logR.isErr || logR.okOrNull == null) {
      _logger.warn(
        'MemoryIngestionCoordinator: getLog after ingest failed — '
        'skipping memory extraction',
      );
      return Ok<IngestionOutcome, AppError>(
        IngestionOutcome(
          logId: logId,
          consolidation: _emptyConsolidation(),
        ),
      );
    }
    final chunks = logR.okOrNull!.chunks;

    final extractR = await extractor.extract(
      cleaned: cleaned,
      chunks: chunks,
      recordingDate: recording.startedAt,
    );
    if (extractR.isErr) {
      _logger.warn(
        'MemoryIngestionCoordinator: extract failed: '
        '${extractR.errOrNull}',
      );
      return Ok<IngestionOutcome, AppError>(
        IngestionOutcome(
          logId: logId,
          consolidation: _emptyConsolidation(),
        ),
      );
    }
    final candidates = extractR.okOrNull!;

    if (candidates.isEmpty) {
      return Ok<IngestionOutcome, AppError>(
        IngestionOutcome(
          logId: logId,
          consolidation: _emptyConsolidation(),
        ),
      );
    }

    final consR = await consolidator.consolidate(candidates);
    if (consR.isErr) {
      _logger.warn(
        'MemoryIngestionCoordinator: consolidate failed: '
        '${consR.errOrNull}',
      );
      return Ok<IngestionOutcome, AppError>(
        IngestionOutcome(
          logId: logId,
          consolidation: _emptyConsolidation(),
        ),
      );
    }
    final consolidation = consR.okOrNull!;

    // Only mark stale when something structurally changed — pure
    // "merge" batches don't warrant rebuilding the profile blurb.
    if (consolidation.isStructurallyChanged) {
      final staleR = await profileBuilder.markStale();
      if (staleR.isErr) {
        _logger.warn(
          'MemoryIngestionCoordinator: markStale failed: '
          '${staleR.errOrNull}',
        );
      }
    }

    return Ok<IngestionOutcome, AppError>(
      IngestionOutcome(logId: logId, consolidation: consolidation),
    );
  }

  static ConsolidationResult _emptyConsolidation() =>
      const ConsolidationResult(
        created: <Memory>[],
        merged: <Memory>[],
        superseded: <SupersededPair>[],
        dropped: <String>[],
      );
}
