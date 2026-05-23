import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/actions/action_extractor.dart';
import '../../features/actions/action_job.dart';
import '../../features/actions/local_notification_scheduler.dart';
import '../../features/digest/digest_runner.dart';
import '../../features/memory/memory_extractor.dart';
import '../../features/memory/memory_job.dart';
import '../../features/record/recording_providers.dart';
import '../../features/record/transcribe_job.dart';
import '../../features/refine/canonicalize_job.dart';
import '../../features/refine/embed_job.dart';
import '../../features/refine/entity_summary_job.dart';
import '../../features/refine/gemma3/gemma3_runner.dart';
import '../../features/refine/llm_runner.dart';
import '../../features/refine/refine_runner.dart';
import '../../features/search/canonicalizer.dart';
import '../../features/search/embedder.dart';
import '../../features/search/segment_repository.dart';
import '../../features/search/vec_store.dart';
import '../../features/summarize/summarize_runner.dart';
import '../db/job_state.dart';
import '../db/providers.dart';
import '../model_bootstrap.dart';
import '../pipeline_debug_provider.dart';
import 'job_handler.dart';
import 'job_queue.dart';
import 'worker.dart';

/// Drift-backed job queue. Single instance per database.
final jobQueueProvider = Provider<JobQueue>((ref) {
  final db = ref.watch(voxSynthDatabaseProvider);
  return JobQueue(db);
});

/// Long-lived Gemma 3 1B runner. The runner serializes all LLM calls and
/// releases the native model after an idle TTL when refine/memory jobs go quiet.
final llmRunnerProvider = Provider<LlmRunner>((ref) {
  final runner = Gemma3Runner();
  ref.onDispose(runner.dispose);
  return runner;
});

/// Handler for the `transcribe` job type. Parakeet ASR runs in a background
/// isolate; the recording controller enqueues this immediately after the
/// audio file is captured so the user is freed from the record screen
/// before transcription completes.
final transcribeHandlerProvider = Provider<JobHandler>((ref) {
  return TranscribeJobHandler(
    repository: ref.watch(voiceLogRepositoryProvider),
    segmentRepository: ref.watch(transcriptSegmentRepositoryProvider),
    recognizerFactory: ref.watch(speechRecognizerFactoryProvider),
    queue: ref.watch(jobQueueProvider),
    docsPath: ref.watch(appDocumentsPathProvider),
  );
});

/// Handler for the `refine` job type. Gemma 3 1B runs cleanup first and then
/// extracts exact-substring entities from the cleaned transcript. Load failures
/// bubble into the worker retry/fail path so absence of the gated model asset
/// does not crash the app.
final refineHandlerProvider = Provider<JobHandler>((ref) {
  final repo = ref.watch(voiceLogRepositoryProvider);
  final mentions = ref.watch(entityMentionRepositoryProvider);
  final queue = ref.watch(jobQueueProvider);
  final runner = ref.watch(llmRunnerProvider);
  final suggestions = ref.watch(promptSuggestionRepositoryProvider);
  return LlmRefiner(
    runner: runner,
    voiceLogs: repo,
    mentions: mentions,
    queue: queue,
    suggestions: suggestions,
  );
});

/// Segment repository used by the embed job and vector search.
final segmentRepositoryProvider = Provider<SegmentRepository>((ref) {
  final db = ref.watch(voxSynthDatabaseProvider);
  return SegmentRepository(db);
});

/// Lazy e5 embedder. Asset copy/model load happens only when a job or
/// search query first needs embeddings.
final embedderProvider = Provider<Embedder>((ref) {
  final embedder = LazyE5Embedder(bootstrap: ModelBootstrap());
  ref.onDispose(() => unawaited(embedder.dispose()));
  return embedder;
});

/// In-memory vector store warmed from persisted segments and updated by
/// each successful embed job.
final vecStoreProvider = Provider<VecStore>((ref) {
  final store = VecStore(ref.watch(segmentRepositoryProvider));
  unawaited(store.load());
  return store;
});

/// Handler for the `embed` job type. Runs e5, persists segments, and
/// then enqueues canonicalization.
final embedHandlerProvider = Provider<JobHandler>((ref) {
  return EmbedJobHandler(
    embedder: ref.watch(embedderProvider),
    repository: ref.watch(voiceLogRepositoryProvider),
    segmentRepository: ref.watch(segmentRepositoryProvider),
    vecStore: ref.watch(vecStoreProvider),
    queue: ref.watch(jobQueueProvider),
  );
});

/// Handler for the `canonicalize` job type. Links mention rows to the
/// user's canonical entity graph after embeddings are available.
final canonicalizeHandlerProvider = Provider<JobHandler>((ref) {
  final db = ref.watch(voxSynthDatabaseProvider);
  return CanonicalizeJobHandler(
    voiceLogs: ref.watch(voiceLogRepositoryProvider),
    queue: ref.watch(jobQueueProvider),
    mentions: ref.watch(entityMentionRepositoryProvider),
    canonicalizer: Canonicalizer(
      db: db,
      embedder: ref.watch(embedderProvider),
      mentions: ref.watch(entityMentionRepositoryProvider),
      canonicals: ref.watch(canonicalEntityRepositoryProvider),
    ),
  );
});

/// Local notification scheduler for extracted reminders.
final localNotificationSchedulerProvider = Provider<LocalNotificationScheduler>(
  (ref) => FlutterLocalNotificationScheduler(),
);

/// Handler for the `action` job type. Extracts action items and schedules
/// local notifications for future reminders.
final actionHandlerProvider = Provider<JobHandler>((ref) {
  return ActionJobHandler(
    voiceLogs: ref.watch(voiceLogRepositoryProvider),
    actions: ref.watch(actionItemRepositoryProvider),
    extractor: ActionExtractor(runner: ref.watch(llmRunnerProvider)),
    notifications: ref.watch(localNotificationSchedulerProvider),
  );
});

/// Handler for the `summarize` job type. Runs after refine and writes a
/// structured per-log summary (one-liner, bullets, people/projects,
/// decisions, follow-ups) into the `summaries` table.
final summarizeHandlerProvider = Provider<JobHandler>((ref) {
  return SummarizeRunner(
    runner: ref.watch(llmRunnerProvider),
    voiceLogs: ref.watch(voiceLogRepositoryProvider),
    summaries: ref.watch(logSummaryRepositoryProvider),
  );
});

/// Handler for the `entity_summary` job type. JobContext.logId carries a
/// canonical entity id here, not a voice-log id — the queue keys every
/// job on a single string column so we reuse it for entity-scoped work.
final entitySummaryHandlerProvider = Provider<JobHandler>((ref) {
  return EntitySummaryJobHandler(
    runner: ref.watch(llmRunnerProvider),
    canonicals: ref.watch(canonicalEntityRepositoryProvider),
    mentions: ref.watch(entityMentionRepositoryProvider),
    voiceLogs: ref.watch(voiceLogRepositoryProvider),
    summaries: ref.watch(entitySummaryRepositoryProvider),
  );
});

/// Handler for the `digest` job type. JobContext.logId carries a digest
/// target string here (e.g. `daily:2026-05-15`), not a voice-log id —
/// the queue keys every job on a single string column so we reuse it for
/// cross-log work.
final digestHandlerProvider = Provider<JobHandler>((ref) {
  return DigestRunner(
    runner: ref.watch(llmRunnerProvider),
    voiceLogs: ref.watch(voiceLogRepositoryProvider),
    summaries: ref.watch(logSummaryRepositoryProvider),
  );
});

/// Handler for the `memory` job type. Extracts durable local memories after
/// canonicalization, embeds the memory cards, and persists evidence links.
final memoryHandlerProvider = Provider<JobHandler>((ref) {
  return MemoryJobHandler(
    voiceLogs: ref.watch(voiceLogRepositoryProvider),
    mentions: ref.watch(entityMentionRepositoryProvider),
    extractor: MemoryExtractor(runner: ref.watch(llmRunnerProvider)),
    embedder: ref.watch(embedderProvider),
    memories: ref.watch(memoryRepositoryProvider),
  );
});

/// The live worker. Kept alive for the session so background jobs keep
/// ticking even when no screen is subscribed. The caller is responsible
/// for invoking [Worker.start] after the first frame so plugin channels
/// (e.g. `path_provider_android` → `jni`) are fully attached before the
/// worker hits the DB.
final workerProvider = Provider<Worker>((ref) {
  ref.keepAlive();
  final queue = ref.watch(jobQueueProvider);
  final handlers = <JobType, JobHandler>{
    JobType.transcribe: ref.watch(transcribeHandlerProvider),
    JobType.refine: ref.watch(refineHandlerProvider),
    JobType.embed: ref.watch(embedHandlerProvider),
    JobType.canonicalize: ref.watch(canonicalizeHandlerProvider),
    JobType.memory: ref.watch(memoryHandlerProvider),
    JobType.action: ref.watch(actionHandlerProvider),
    JobType.summarize: ref.watch(summarizeHandlerProvider),
    JobType.entitySummary: ref.watch(entitySummaryHandlerProvider),
    JobType.digest: ref.watch(digestHandlerProvider),
  };
  final repo = ref.watch(voiceLogRepositoryProvider);
  final worker = Worker(
    queue: queue,
    handlers: handlers,
    onJobSucceeded: (job) async {
      if (job.jobType != JobType.refine) return;
      ref.invalidate(voiceLogsStreamProvider);
      ref.read(voiceLogListRevisionProvider.notifier).state++;
      ref
          .read(recordingControllerProvider.notifier)
          .onRefineSucceeded(job.logId);
    },
    onPermanentFailure: (job, reason) async {
      await repo.markFailed(
        id: job.logId,
        errorMessage: '${job.jobType.wire} failed: $reason',
      );
      if (job.jobType == JobType.refine) {
        ref
            .read(recordingControllerProvider.notifier)
            .onRefineFailed(job.logId);
      }
    },
    debugSink: ref.watch(pipelineDebugSinkProvider),
  );
  ref.onDispose(worker.stop);
  return worker;
});
