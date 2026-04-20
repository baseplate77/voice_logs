import 'package:flutter_test/flutter_test.dart';
import 'package:voxsynth/embed/embedder.dart';
import 'package:voxsynth/llm/llm_runner.dart';
import 'package:voxsynth/store/database_factory.dart';
import 'package:voxsynth/store/voice_log_repository.dart';
import 'package:voxsynth/synth/background/daily_brief_job.dart';
import 'package:voxsynth/synth/background/models/synthesis_kind.dart';
import 'package:voxsynth/synth/background/monthly_shifts_job.dart';
import 'package:voxsynth/synth/background/scheduler.dart';
import 'package:voxsynth/synth/background/weekly_themes_job.dart';

Future<BackgroundScheduler> _build({
  required FakeJobQueue queue,
  List<String> dailyScript = const <String>[],
  List<String> weeklyScript = const <String>[],
  List<String> monthlyScript = const <String>[],
}) async {
  final db = openInMemoryAppDatabase();
  await db.customSelect('SELECT 1').get();
  final embedder = FakeEmbedder();
  await embedder.load();
  final repo = VoiceLogRepository(
    db,
    embedder: embedder,
    audioFileDeleter: (_) async {},
  );
  final dailyRunner = FakeLlmRunner(responses: dailyScript);
  await dailyRunner.load();
  final weeklyRunner = FakeLlmRunner(responses: weeklyScript);
  await weeklyRunner.load();
  final monthlyRunner = FakeLlmRunner(responses: monthlyScript);
  await monthlyRunner.load();
  return BackgroundScheduler(
    queue: queue,
    dailyBrief: DailyBriefJob(
      repository: repo,
      runner: dailyRunner,
      clock: () => DateTime(2026, 4, 19, 12),
    ),
    weeklyThemes: WeeklyThemesJob(
      repository: repo,
      runner: weeklyRunner,
      clock: () => DateTime(2026, 4, 19, 12),
    ),
    monthlyShifts: MonthlyShiftsJob(
      repository: repo,
      runner: monthlyRunner,
      clock: () => DateTime(2026, 4, 19, 12),
    ),
  );
}

void main() {
  group('BackgroundScheduler', () {
    test('jobs getter returns all 3 kinds with correct cadence',
        () async {
      final queue = FakeJobQueue();
      final s = await _build(queue: queue);
      expect(s.jobs, hasLength(3));
      expect(
        s.jobs.map((j) => j.name).toSet(),
        <String>{
          kSynthesisKindDailyBrief,
          kSynthesisKindWeeklyThemes,
          kSynthesisKindMonthlyShifts,
        },
      );
      expect(
        s.jobs
            .firstWhere((j) => j.name == kSynthesisKindDailyBrief)
            .frequency,
        kDailyBriefFrequency,
      );
      expect(
        s.jobs
            .firstWhere((j) => j.name == kSynthesisKindWeeklyThemes)
            .frequency,
        kWeeklyThemesFrequency,
      );
      expect(
        s.jobs
            .firstWhere((j) => j.name == kSynthesisKindMonthlyShifts)
            .frequency,
        kMonthlyShiftsFrequency,
      );
    });

    test('registerAll pushes all 3 into the queue with constraints',
        () async {
      final queue = FakeJobQueue();
      final s = await _build(queue: queue);
      final r = await s.registerAll();
      expect(r.isOk, isTrue);
      expect(queue.registerCalls, 1);
      expect(queue.registered, hasLength(3));
      for (final reg in queue.registered) {
        expect(reg.constraints, kBackgroundJobConstraints);
        expect(reg.maxRuntime, kBackgroundJobMaxRuntime);
      }
    });

    test('registerAll is idempotent — re-registration replaces',
        () async {
      final queue = FakeJobQueue();
      final s = await _build(queue: queue);
      await s.registerAll();
      await s.registerAll();
      expect(queue.registerCalls, 2);
      // Still 3 entries (not 6), because FakeJobQueue.register
      // overwrites registered list.
      expect(queue.registered, hasLength(3));
    });

    test('cancelAll delegates to the queue', () async {
      final queue = FakeJobQueue();
      final s = await _build(queue: queue);
      await s.registerAll();
      final r = await s.cancelAll();
      expect(r.isOk, isTrue);
      expect(queue.cancelAllCalls, 1);
      expect(queue.registered, isEmpty);
    });

    test('runOnce dispatches to DailyBriefJob', () async {
      final queue = FakeJobQueue();
      final s = await _build(queue: queue);
      final r = await s.runOnce(kSynthesisKindDailyBrief);
      expect(r.isOk, isTrue);
    });

    test('runOnce dispatches to WeeklyThemesJob', () async {
      final queue = FakeJobQueue();
      final s = await _build(queue: queue);
      final r = await s.runOnce(kSynthesisKindWeeklyThemes);
      expect(r.isOk, isTrue);
    });

    test('runOnce dispatches to MonthlyShiftsJob', () async {
      final queue = FakeJobQueue();
      final s = await _build(queue: queue);
      final r = await s.runOnce(kSynthesisKindMonthlyShifts);
      expect(r.isOk, isTrue);
    });

    test('runOnce returns Err for unknown names', () async {
      final queue = FakeJobQueue();
      final s = await _build(queue: queue);
      final r = await s.runOnce('what_is_this');
      expect(r.isErr, isTrue);
      expect(r.errOrNull.toString(), contains('what_is_this'));
    });
  });

  group('JobConstraints', () {
    test('VoxSynth default is battery-aware, idle-only, offline-ok',
        () {
      const c = kBackgroundJobConstraints;
      expect(c.requiresCharging, isFalse);
      expect(c.requiresBatteryNotLow, isTrue);
      expect(c.requiresDeviceIdle, isTrue);
      expect(c.requiresNetwork, isFalse);
    });
  });
}
