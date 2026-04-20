import 'package:meta/meta.dart';
import 'package:workmanager/workmanager.dart' as wm;

import '../../core/errors.dart';
import '../../core/logger.dart';
import '../../core/result.dart';
import '../../memory/background/memory_consolidation_job.dart';
import '../../memory/background/profile_refresh_job.dart';
import 'daily_brief_job.dart';
import 'models/synthesis_kind.dart';
import 'monthly_shifts_job.dart';
import 'weekly_themes_job.dart';

/// All three Phase 7 jobs share these constraints — the plan
/// (IMPLEMENTATION_PLAN §8) wants them to fire only when the device
/// can spare the CPU: charging or battery > 50%, idle, network-type
/// doesn't matter because VoxSynth is local-only.
const JobConstraints kBackgroundJobConstraints = JobConstraints(
  requiresCharging: false,
  requiresBatteryNotLow: true,
  requiresDeviceIdle: true,
  requiresNetwork: false,
);

/// Upper bound for a single run on-device. The plan's acceptance
/// criterion is "all jobs complete in under 60s on target hardware";
/// we set a 90s kill switch so the OS doesn't kill us first, leaving
/// a torn half-written synthesis.
const Duration kBackgroundJobMaxRuntime = Duration(seconds: 90);

/// When each job fires. These are wall-clock frequencies enforced by
/// the underlying [JobQueue]; actual execution is subject to OS
/// scheduling + the constraints above, so the fire time is a
/// soft target, not a hard deadline.
const Duration kDailyBriefFrequency = Duration(days: 1);
const Duration kWeeklyThemesFrequency = Duration(days: 7);
const Duration kMonthlyShiftsFrequency = Duration(days: 30);

/// Phase 8 — weekly memory sweep.
const Duration kMemoryConsolidationFrequency = Duration(days: 7);

/// Phase 8 — daily profile rebuild when stale.
const Duration kProfileRefreshFrequency = Duration(days: 1);

/// Constraints on a periodic job — abstracted over the underlying
/// platform scheduler. Maps 1:1 to `workmanager`'s `Constraints` on
/// Android and `BGTaskScheduler` requirements on iOS.
@immutable
final class JobConstraints {
  const JobConstraints({
    required this.requiresCharging,
    required this.requiresBatteryNotLow,
    required this.requiresDeviceIdle,
    required this.requiresNetwork,
  });

  final bool requiresCharging;
  final bool requiresBatteryNotLow;
  final bool requiresDeviceIdle;

  /// When false (the default for VoxSynth), the job runs on any
  /// connectivity state including offline.
  final bool requiresNetwork;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is JobConstraints &&
          other.requiresCharging == requiresCharging &&
          other.requiresBatteryNotLow == requiresBatteryNotLow &&
          other.requiresDeviceIdle == requiresDeviceIdle &&
          other.requiresNetwork == requiresNetwork);

  @override
  int get hashCode => Object.hash(
        requiresCharging,
        requiresBatteryNotLow,
        requiresDeviceIdle,
        requiresNetwork,
      );
}

/// Single registration request: a named periodic job with the
/// cadence and constraints it runs under.
@immutable
final class JobRegistration {
  const JobRegistration({
    required this.name,
    required this.frequency,
    required this.constraints,
    this.maxRuntime = kBackgroundJobMaxRuntime,
  });

  final String name;
  final Duration frequency;
  final JobConstraints constraints;
  final Duration maxRuntime;
}

/// Platform-agnostic job queue. [WorkmanagerJobQueue] is the real
/// impl; [FakeJobQueue] lets tests assert what got scheduled.
abstract class JobQueue {
  /// Register [jobs] as periodic tasks. Implementations must be
  /// idempotent — re-registering by the same name replaces the
  /// previous schedule rather than stacking duplicates.
  Future<Result<void, AppError>> register(List<JobRegistration> jobs);

  /// Cancel everything this queue knows about. Called from "reset" UI
  /// affordances + during dev-mode reshuffles.
  Future<Result<void, AppError>> cancelAll();
}

/// Real implementation over the `workmanager` package. Android uses
/// `registerPeriodicTask`; iOS uses `BGTaskScheduler` under the hood
/// (both abstracted behind the same Dart API).
class WorkmanagerJobQueue implements JobQueue {
  WorkmanagerJobQueue({wm.Workmanager? workmanager, AppLogger? logger})
      : _wm = workmanager ?? wm.Workmanager(),
        _logger = logger ?? AppLogger();

  final wm.Workmanager _wm;
  final AppLogger _logger;

  @override
  Future<Result<void, AppError>> register(
    List<JobRegistration> jobs,
  ) async {
    try {
      for (final job in jobs) {
        await _wm.registerPeriodicTask(
          job.name,
          job.name,
          frequency: job.frequency,
          constraints: wm.Constraints(
            networkType: job.constraints.requiresNetwork
                ? wm.NetworkType.connected
                : wm.NetworkType.notRequired,
            requiresCharging: job.constraints.requiresCharging,
            requiresBatteryNotLow: job.constraints.requiresBatteryNotLow,
            requiresDeviceIdle: job.constraints.requiresDeviceIdle,
            requiresStorageNotLow: false,
          ),
          existingWorkPolicy: wm.ExistingPeriodicWorkPolicy.replace,
        );
      }
      return const Ok<void, AppError>(null);
    } on Object catch (e, st) {
      _logger.error('workmanager register failed',
          error: e, stackTrace: st);
      return Err<void, AppError>(
        UnknownError('workmanager register failed',
            cause: e, stackTrace: st),
      );
    }
  }

  @override
  Future<Result<void, AppError>> cancelAll() async {
    try {
      await _wm.cancelAll();
      return const Ok<void, AppError>(null);
    } on Object catch (e, st) {
      _logger.error('workmanager cancelAll failed',
          error: e, stackTrace: st);
      return Err<void, AppError>(
        UnknownError('workmanager cancelAll failed',
            cause: e, stackTrace: st),
      );
    }
  }
}

/// In-memory JobQueue for tests. Records the most recent register()
/// argument so specs can assert which jobs got scheduled with which
/// cadence.
class FakeJobQueue implements JobQueue {
  FakeJobQueue();

  List<JobRegistration> registered = const <JobRegistration>[];
  int registerCalls = 0;
  int cancelAllCalls = 0;

  @override
  Future<Result<void, AppError>> register(
    List<JobRegistration> jobs,
  ) async {
    registerCalls++;
    registered = List<JobRegistration>.unmodifiable(jobs);
    return const Ok<void, AppError>(null);
  }

  @override
  Future<Result<void, AppError>> cancelAll() async {
    cancelAllCalls++;
    registered = const <JobRegistration>[];
    return const Ok<void, AppError>(null);
  }
}

/// Top-level background-jobs coordinator. Holds Phase 7 + optional
/// Phase 8 job instances + the queue, exposes `registerAll()` (called
/// once on app startup) and `runOnce(name)` (dev hook).
class BackgroundScheduler {
  BackgroundScheduler({
    required this.queue,
    required this.dailyBrief,
    required this.weeklyThemes,
    required this.monthlyShifts,
    this.memoryConsolidation,
    this.profileRefresh,
    AppLogger? logger,
  }) : _logger = logger ?? AppLogger();

  final JobQueue queue;
  final DailyBriefJob dailyBrief;
  final WeeklyThemesJob weeklyThemes;
  final MonthlyShiftsJob monthlyShifts;

  /// Phase 8 — nullable so callers that haven't wired the memory
  /// subsystem (simpler bootstraps, tests) can still construct the
  /// scheduler. When null the job isn't registered.
  final MemoryConsolidationJob? memoryConsolidation;

  /// Phase 8 — nullable like [memoryConsolidation].
  final ProfileRefreshJob? profileRefresh;

  final AppLogger _logger;

  /// All registered jobs with cadences + constraints. Phase 8 jobs
  /// are included only when their corresponding job instance was
  /// supplied to the constructor.
  List<JobRegistration> get jobs => <JobRegistration>[
        const JobRegistration(
          name: kSynthesisKindDailyBrief,
          frequency: kDailyBriefFrequency,
          constraints: kBackgroundJobConstraints,
        ),
        const JobRegistration(
          name: kSynthesisKindWeeklyThemes,
          frequency: kWeeklyThemesFrequency,
          constraints: kBackgroundJobConstraints,
        ),
        const JobRegistration(
          name: kSynthesisKindMonthlyShifts,
          frequency: kMonthlyShiftsFrequency,
          constraints: kBackgroundJobConstraints,
        ),
        if (memoryConsolidation != null)
          const JobRegistration(
            name: kJobKindMemoryConsolidation,
            frequency: kMemoryConsolidationFrequency,
            constraints: kBackgroundJobConstraints,
          ),
        if (profileRefresh != null)
          const JobRegistration(
            name: kJobKindProfileRefresh,
            frequency: kProfileRefreshFrequency,
            constraints: kBackgroundJobConstraints,
          ),
      ];

  /// Register all known jobs with the underlying [queue]. Idempotent
  /// (the queue's register() replaces existing entries by name).
  Future<Result<void, AppError>> registerAll() => queue.register(jobs);

  /// Cancel everything. Useful for "reset" UI affordances or before a
  /// reshuffle.
  Future<Result<void, AppError>> cancelAll() => queue.cancelAll();

  /// Dev hook: run one job immediately in the foreground, bypassing
  /// the queue. Intended for debug screens; production never calls
  /// this. Returns `Err(UnknownError)` if [name] doesn't match a job.
  Future<Result<void, AppError>> runOnce(String name) async {
    _logger.info('BackgroundScheduler.runOnce("$name")');
    switch (name) {
      case kSynthesisKindDailyBrief:
        final r = await dailyBrief.run();
        return r.isOk
            ? const Ok<void, AppError>(null)
            : Err<void, AppError>(r.errOrNull!);
      case kSynthesisKindWeeklyThemes:
        final r = await weeklyThemes.run();
        return r.isOk
            ? const Ok<void, AppError>(null)
            : Err<void, AppError>(r.errOrNull!);
      case kSynthesisKindMonthlyShifts:
        final r = await monthlyShifts.run();
        return r.isOk
            ? const Ok<void, AppError>(null)
            : Err<void, AppError>(r.errOrNull!);
      case kJobKindMemoryConsolidation:
        final job = memoryConsolidation;
        if (job == null) {
          return const Err<void, AppError>(
            UnknownError('memory consolidation job not configured'),
          );
        }
        final r = await job.run();
        return r.isOk
            ? const Ok<void, AppError>(null)
            : Err<void, AppError>(r.errOrNull!);
      case kJobKindProfileRefresh:
        final job = profileRefresh;
        if (job == null) {
          return const Err<void, AppError>(
            UnknownError('profile refresh job not configured'),
          );
        }
        final r = await job.run();
        return r.isOk
            ? const Ok<void, AppError>(null)
            : Err<void, AppError>(r.errOrNull!);
      default:
        return Err<void, AppError>(
          UnknownError('unknown job name: "$name"'),
        );
    }
  }
}
