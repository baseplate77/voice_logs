import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voxsynth/app.dart';
import 'package:voxsynth/core/db/database.dart';
import 'package:voxsynth/core/db/job_state.dart';
import 'package:voxsynth/core/db/providers.dart';
import 'package:voxsynth/core/worker/job_handler.dart';
import 'package:voxsynth/core/worker/providers.dart';
import 'package:voxsynth/core/worker/worker.dart';
import 'package:voxsynth/features/home/auto_record_provider.dart';

void main() {
  testWidgets('VoxSynthApp boots and shows onboarding on first launch', (
    tester,
  ) async {
    final db = VoxSynthDatabase(NativeDatabase.memory());
    addTearDown(db.close);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          voxSynthDatabaseProvider.overrideWithValue(db),
          voiceLogsStreamProvider.overrideWith((_) => Stream.value(const [])),
          onboardingCompleteProvider.overrideWith(
            (_) => _FixedOnboardingNotifier(false),
          ),
          workerProvider.overrideWith((ref) {
            final queue = ref.watch(jobQueueProvider);
            final worker = Worker(
              queue: queue,
              handlers: <JobType, JobHandler>{},
              pollInterval: const Duration(days: 1),
            );
            ref.onDispose(worker.stop);
            return worker;
          }),
        ],
        child: const VoxSynthApp(),
      ),
    );
    await tester.pump();

    expect(find.text('VoxSynth'), findsWidgets);
    expect(
      find.textContaining('Recording starts automatically'),
      findsOneWidget,
    );
  });

  testWidgets('VoxSynthApp shows log list when onboarded', (tester) async {
    final db = VoxSynthDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final tmpDir = Directory.systemTemp.createTempSync('vox_test_');
    addTearDown(() => tmpDir.deleteSync(recursive: true));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDocumentsPathProvider.overrideWithValue(tmpDir.path),
          voxSynthDatabaseProvider.overrideWithValue(db),
          voiceLogsStreamProvider.overrideWith((_) => Stream.value(const [])),
          onboardingCompleteProvider.overrideWith(
            (_) => _FixedOnboardingNotifier(true),
          ),
          autoRecordEnabledProvider.overrideWith(
            (_) => _FixedAutoRecordNotifier(false),
          ),
          workerProvider.overrideWith((ref) {
            final queue = ref.watch(jobQueueProvider);
            final worker = Worker(
              queue: queue,
              handlers: <JobType, JobHandler>{},
              pollInterval: const Duration(days: 1),
            );
            ref.onDispose(worker.stop);
            return worker;
          }),
        ],
        child: const VoxSynthApp(),
      ),
    );
    await tester.pump();

    expect(find.text('VoxSynth'), findsOneWidget);
    expect(find.textContaining('smarter'), findsOneWidget);
  });
}

class _FixedOnboardingNotifier extends OnboardingCompleteNotifier {
  _FixedOnboardingNotifier(bool value) {
    state = AsyncValue.data(value);
  }

  @override
  Future<void> markComplete() async {
    state = const AsyncValue.data(true);
  }
}

class _FixedAutoRecordNotifier extends AutoRecordEnabledNotifier {
  _FixedAutoRecordNotifier(bool value) {
    state = value;
  }

  @override
  Future<void> toggle() async {
    state = !state;
  }
}
