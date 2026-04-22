import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/refine/gemma_refiner.dart';
import '../../features/refine/gemma_runner.dart';
import '../../features/refine/llm_runner.dart';
import '../db/job_state.dart';
import '../db/providers.dart';
import 'job_handler.dart';
import 'job_queue.dart';
import 'worker.dart';

/// Drift-backed job queue. Single instance per database.
final jobQueueProvider = Provider<JobQueue>((ref) {
  final db = ref.watch(voxSynthDatabaseProvider);
  return JobQueue(db);
});

/// Long-lived Gemma runner — one model per session.
final llmRunnerProvider = Provider<LlmRunner>((ref) {
  final runner = GemmaRunner();
  ref.onDispose(runner.dispose);
  return runner;
});

/// Handler for the `refine` job type. Phase 4 uses [GemmaRefiner]; load
/// failures bubble back into the worker's retry/fail path so absence of
/// the model asset doesn't crash the app.
final refineHandlerProvider = Provider<JobHandler>((ref) {
  final repo = ref.watch(voiceLogRepositoryProvider);
  final mentions = ref.watch(entityMentionRepositoryProvider);
  final queue = ref.watch(jobQueueProvider);
  final runner = ref.watch(llmRunnerProvider);
  return GemmaRefiner(
    runner: runner,
    voiceLogs: repo,
    mentions: mentions,
    queue: queue,
  );
});

/// Handler for the `embed` job type. Wired in Phase 3; Phase 4's Gemma
/// path replaces the refine handler but leaves this one untouched.
final embedHandlerProvider = Provider<JobHandler?>((ref) {
  // Embed requires the full e5 stack (model bootstrap + tokenizer).
  // Phase 3 wires it up when the model assets are present; absence is
  // handled by omitting the handler from the worker's dispatch map.
  return null;
});

/// The live worker. Kept alive for the session so background jobs keep
/// ticking even when no screen is subscribed.
final workerProvider = Provider<Worker>((ref) {
  ref.keepAlive();
  final queue = ref.watch(jobQueueProvider);
  final embedHandler = ref.watch(embedHandlerProvider);
  final handlers = <JobType, JobHandler>{
    JobType.refine: ref.watch(refineHandlerProvider),
  };
  if (embedHandler != null) handlers[JobType.embed] = embedHandler;
  final worker = Worker(queue: queue, handlers: handlers);
  // Fire-and-forget start — polling begins on first read.
  worker.start();
  ref.onDispose(worker.stop);
  return worker;
});
