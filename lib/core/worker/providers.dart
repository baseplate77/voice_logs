import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/memory/memory_extractor.dart';
import '../../features/memory/memory_job.dart';
import '../../features/refine/canonicalize_job.dart';
import '../../features/refine/embed_job.dart';
import '../../features/refine/gemma3/gemma3_runner.dart';
import '../../features/refine/llm_runner.dart';
import '../../features/refine/refine_runner.dart';
import '../../features/search/canonicalizer.dart';
import '../../features/search/embedder.dart';
import '../../features/search/segment_repository.dart';
import '../../features/search/vec_store.dart';
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

/// Handler for the `refine` job type. Gemma 3 1B runs cleanup first and then
/// extracts exact-substring entities from the cleaned transcript. Load failures
/// bubble into the worker retry/fail path so absence of the gated model asset
/// does not crash the app.
final refineHandlerProvider = Provider<JobHandler>((ref) {
  final repo = ref.watch(voiceLogRepositoryProvider);
  final mentions = ref.watch(entityMentionRepositoryProvider);
  final queue = ref.watch(jobQueueProvider);
  final runner = ref.watch(llmRunnerProvider);
  return LlmRefiner(
    runner: runner,
    voiceLogs: repo,
    mentions: mentions,
    queue: queue,
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
    canonicalizer: Canonicalizer(
      db: db,
      embedder: ref.watch(embedderProvider),
      mentions: ref.watch(entityMentionRepositoryProvider),
      canonicals: ref.watch(canonicalEntityRepositoryProvider),
    ),
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
    JobType.refine: ref.watch(refineHandlerProvider),
    JobType.embed: ref.watch(embedHandlerProvider),
    JobType.canonicalize: ref.watch(canonicalizeHandlerProvider),
    JobType.memory: ref.watch(memoryHandlerProvider),
  };
  final repo = ref.watch(voiceLogRepositoryProvider);
  final worker = Worker(
    queue: queue,
    handlers: handlers,
    onPermanentFailure: (job, reason) async {
      await repo.markFailed(
        id: job.logId,
        errorMessage: '${job.jobType.wire} failed: $reason',
      );
    },
    debugSink: ref.watch(pipelineDebugSinkProvider),
  );
  ref.onDispose(worker.stop);
  return worker;
});
