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

void main() {
  testWidgets('VoxSynthApp boots and shows onboarding copy when empty', (
    tester,
  ) async {
    final db = VoxSynthDatabase(NativeDatabase.memory());
    addTearDown(db.close);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          voxSynthDatabaseProvider.overrideWithValue(db),
          // Emit the empty-state list synchronously so the loading
          // spinner (which spins forever on a Timer) never renders.
          voiceLogsStreamProvider.overrideWith((_) => Stream.value(const [])),
          // Inert worker — the real provider starts a polling Timer
          // that leaks into the test harness.
          workerProvider.overrideWith((ref) {
            final queue = ref.watch(jobQueueProvider);
            return Worker(
              queue: queue,
              handlers: <JobType, JobHandler>{},
              pollInterval: const Duration(days: 1),
            );
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
