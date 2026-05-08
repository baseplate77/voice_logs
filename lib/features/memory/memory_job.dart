import '../../core/app_error.dart';
import '../../core/db/job_state.dart';
import '../../core/db/repositories/entity_mention_repository.dart';
import '../../core/db/repositories/memory_repository.dart';
import '../../core/db/repositories/voice_log_repository.dart';
import '../../core/result.dart';
import '../../core/worker/job_handler.dart';
import '../search/embedder.dart';
import 'memory_extractor.dart';
import 'memory_types.dart';

/// Worker handler for local memory extraction. Runs after canonicalization so
/// extracted memory cards can link to canonical entities when evidence overlaps
/// entity mentions.
class MemoryJobHandler implements JobHandler {
  MemoryJobHandler({
    required this.voiceLogs,
    required this.mentions,
    required this.extractor,
    required this.embedder,
    required this.memories,
  });

  final VoiceLogRepository voiceLogs;
  final EntityMentionRepository mentions;
  final MemoryExtractor extractor;
  final Embedder embedder;
  final MemoryRepository memories;

  @override
  JobType get type => JobType.memory;

  @override
  Future<Result<JobOutcome, AppError>> handle(JobContext ctx) async {
    final log = await voiceLogs.find(ctx.logId);
    if (log == null) {
      return const Ok(JobFailedPermanently('log not found'));
    }
    final text = log.cleanedText ?? log.rawTranscript;
    if (text.trim().isEmpty) return const Ok(JobSucceeded());

    final extracted = await extractor.extract(text);
    final List<MemoryCandidate> candidates;
    switch (extracted) {
      case Ok(:final value):
        candidates = value;
      case Err(:final error):
        return Err(error);
    }
    if (candidates.isEmpty) return const Ok(JobSucceeded());

    final loaded = await embedder.load();
    switch (loaded) {
      case Ok():
        break;
      case Err(:final error):
        return Err(error);
    }

    final embedded = await embedder.embedPassages(
      candidates.map((c) => c.text).toList(),
      batchSize: 8,
    );
    switch (embedded) {
      case Err(:final error):
        return Err(error);
      case Ok(:final value):
        final logMentions = await mentions.forLog(ctx.logId);
        for (var i = 0; i < candidates.length; i++) {
          final candidate = candidates[i];
          final entityIds = _overlappingCanonicalEntities(
            candidate,
            logMentions,
          );
          final stored = await memories.createOrUpdate(
            candidate: candidate,
            sourceLogId: ctx.logId,
            embedding: value[i].vector,
            canonicalEntityIds: entityIds,
          );
          switch (stored) {
            case Ok():
              break;
            case Err(:final error):
              return Err(error);
          }
        }
    }
    return const Ok(JobSucceeded());
  }

  List<String> _overlappingCanonicalEntities(
    MemoryCandidate candidate,
    List<EntityMentionView> mentions,
  ) {
    final ids = <String>{};
    for (final mention in mentions) {
      final canonicalId = mention.canonicalEntityId;
      if (canonicalId == null) continue;
      final overlaps =
          candidate.startChar < mention.charEnd &&
          mention.charStart < candidate.endChar;
      if (overlaps) ids.add(canonicalId);
    }
    return ids.toList();
  }
}
