import '../../core/app_error.dart';
import '../../core/db/job_state.dart';
import '../../core/db/repositories/voice_log_repository.dart';
import '../../core/result.dart';
import '../../core/worker/job_handler.dart';
import '../../core/worker/job_queue.dart';
import '../search/embedder.dart';
import '../search/embedding_math.dart';
import '../search/segment_repository.dart';
import '../search/segmenter.dart';
import '../search/vec_store.dart';

/// Handler for `embed` jobs — chunks `cleaned_text` into segments,
/// embeds each with e5-small-v2, persists, and updates the in-memory
/// [VecStore]. Marks the voice log as [ProcessingState.embedded] on
/// success.
class EmbedJobHandler implements JobHandler {
  EmbedJobHandler({
    required this.embedder,
    required this.repository,
    required this.segmentRepository,
    required this.vecStore,
    required this.queue,
  });

  final Embedder embedder;
  final VoiceLogRepository repository;
  final SegmentRepository segmentRepository;
  final VecStore vecStore;
  final JobQueue queue;

  @override
  JobType get type => JobType.embed;

  @override
  Future<Result<JobOutcome, AppError>> handle(JobContext ctx) async {
    final log = await repository.find(ctx.logId);
    if (log == null) {
      return const Ok(JobFailedPermanently('log not found'));
    }
    final text = log.cleanedText ?? log.rawTranscript;
    if (text.trim().isEmpty) {
      await repository.markEmbedded(ctx.logId);
      await queue.enqueue(logId: ctx.logId, type: JobType.canonicalize);
      return const Ok(JobSucceeded());
    }

    final segments = segmentByWords(ctx.logId, text);
    final loaded = await embedder.load();
    switch (loaded) {
      case Ok():
        break;
      case Err(:final error):
        return Err(error);
    }

    final embeddings = await embedder.embedPassages(
      segments.map((s) => s.text).toList(),
      batchSize: 8,
    );
    switch (embeddings) {
      case Ok(:final value):
        final filteredSegments = <TextSegment>[];
        final filteredEmbeddings = <Embedding>[];
        for (var i = 0; i < value.length; i++) {
          if (!isZeroVector(value[i].vector)) {
            filteredSegments.add(segments[i]);
            filteredEmbeddings.add(value[i]);
          }
        }
        final stored = await segmentRepository.upsert(
          logId: ctx.logId,
          segments: filteredSegments,
          embeddings: filteredEmbeddings,
        );
        switch (stored) {
          case Ok():
            // Reflect new segments in the in-memory vec store.
            final fresh = await segmentRepository.all();
            vecStore.replaceForLog(
              ctx.logId,
              fresh.where((s) => s.logId == ctx.logId).toList(),
            );
            await repository.markEmbedded(ctx.logId);
            await queue.enqueue(logId: ctx.logId, type: JobType.canonicalize);
            return const Ok(JobSucceeded());
          case Err(:final error):
            return Err(error);
        }
      case Err(:final error):
        return Err(error);
    }
  }
}
