import 'package:path/path.dart' as p;

import '../../core/app_error.dart';
import '../../core/db/job_state.dart';
import '../../core/db/processing_state.dart';
import '../../core/db/repositories/transcript_segment_repository.dart';
import '../../core/db/repositories/voice_log_repository.dart';
import '../../core/result.dart';
import '../../core/worker/job_handler.dart';
import '../../core/worker/job_queue.dart';
import 'speech_recognizer.dart';

/// Handler for `transcribe` jobs.
///
/// Runs Parakeet ASR on the audio file referenced by the voice-log row,
/// persists the resulting `raw_transcript` plus per-word transcript
/// segments, transitions the row from [ProcessingState.transcribing] to
/// [ProcessingState.recorded], and enqueues a refine job to continue the
/// pipeline.
///
/// Splitting this out of `RecordingController.stop()` is what lets the
/// user return to the home list (and start a new recording) before
/// Parakeet has finished — the spec's "<500ms stop → home" guarantee
/// otherwise can't be met because Parakeet decode runs longer than that
/// on most devices.
class TranscribeJobHandler implements JobHandler {
  TranscribeJobHandler({
    required this.repository,
    required this.segmentRepository,
    required this.recognizerFactory,
    required this.queue,
    required this.docsPath,
  });

  final VoiceLogRepository repository;
  final TranscriptSegmentRepository segmentRepository;
  final Future<SpeechRecognizer> Function() recognizerFactory;
  final JobQueue queue;
  final String docsPath;

  @override
  JobType get type => JobType.transcribe;

  @override
  Future<Result<JobOutcome, AppError>> handle(JobContext ctx) async {
    final log = await repository.find(ctx.logId);
    if (log == null) {
      return const Ok(JobFailedPermanently('log not found'));
    }

    // The stored audio path is relative to the app documents directory so
    // installs that pick a new sandbox path on restore continue to work.
    final absolutePath = p.isAbsolute(log.audioPath)
        ? log.audioPath
        : p.join(docsPath, log.audioPath);

    SpeechRecognizer? recognizer;
    var rawTranscript = '';
    List<TranscriptSegmentResult> segments = const [];
    try {
      recognizer = await recognizerFactory();
      final txt = await recognizer.transcribeFileDetailed(absolutePath);
      switch (txt) {
        case Ok(:final value):
          rawTranscript = value.text;
          segments = value.segments;
        case Err(:final error):
          return Err(error);
      }
    } on Object catch (e, s) {
      return Err(
        _TranscribeError(message: 'Parakeet decode failed: $e', stack: s),
      );
    } finally {
      await recognizer?.dispose();
    }

    final marked = await repository.markTranscribed(
      id: ctx.logId,
      rawTranscript: rawTranscript,
    );
    switch (marked) {
      case Ok():
        break;
      case Err(:final error):
        return Err(error);
    }

    if (segments.isNotEmpty) {
      final persisted = await segmentRepository.replaceForLog(
        logId: ctx.logId,
        segments: segments,
      );
      // Segment persist failure is recoverable — degrade to text-only,
      // don't fail the whole job and block refine.
      if (persisted case Err()) {
        // Swallow; raw transcript is still saved.
      }
    }

    await queue.enqueue(logId: ctx.logId, type: JobType.refine);
    return const Ok(JobSucceeded());
  }
}

class _TranscribeError extends AppError {
  const _TranscribeError({required super.message, super.stack});
}
