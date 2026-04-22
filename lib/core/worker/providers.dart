import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/refine/dummy_refiner.dart';
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

/// Handler for the `refine` job type. Phase 2 uses [DummyRefiner]; Phase
/// 4 will swap in the real Gemma pipeline via this same provider.
final refineHandlerProvider = Provider<JobHandler>((ref) {
  final repo = ref.watch(voiceLogRepositoryProvider);
  return DummyRefiner(repository: repo);
});

/// The live worker. Kept alive for the session so background jobs keep
/// ticking even when no screen is subscribed.
final workerProvider = Provider<Worker>((ref) {
  ref.keepAlive();
  final queue = ref.watch(jobQueueProvider);
  final handlers = <JobType, JobHandler>{
    JobType.refine: ref.watch(refineHandlerProvider),
  };
  final worker = Worker(queue: queue, handlers: handlers);
  // Fire-and-forget start — polling begins on first read.
  worker.start();
  ref.onDispose(worker.stop);
  return worker;
});
