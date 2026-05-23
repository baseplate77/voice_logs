import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voxsynth/app.dart';
import 'package:voxsynth/core/db/database.dart';
import 'package:voxsynth/core/db/job_state.dart';
import 'package:voxsynth/core/db/processing_state.dart';
import 'package:voxsynth/core/db/providers.dart';
import 'package:voxsynth/core/db/repositories/entity_mention_repository.dart';
import 'package:voxsynth/core/db/repositories/voice_log_repository.dart';
import 'package:voxsynth/core/worker/job_handler.dart';
import 'package:voxsynth/core/worker/providers.dart';
import 'package:voxsynth/core/worker/worker.dart';
import 'package:voxsynth/features/home/auto_record_provider.dart';
import 'package:voxsynth/features/list/log_row.dart';

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

    expect(find.text('Think out loud. Privately.'), findsOneWidget);
    expect(find.textContaining('Record your thoughts'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 100));
  });

  testWidgets('VoxSynthApp shows imported logs before onboarding', (
    tester,
  ) async {
    final db = VoxSynthDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final tmpDir = Directory.systemTemp.createTempSync('vox_test_');
    addTearDown(() => tmpDir.deleteSync(recursive: true));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDocumentsPathProvider.overrideWithValue(tmpDir.path),
          voxSynthDatabaseProvider.overrideWithValue(db),
          voiceLogsStreamProvider.overrideWith(
            (_) => Stream.value([
              VoiceLogView(
                id: 'imported-log',
                createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
                durationMs: 1234,
                audioPath: 'audio/imported-log.wav',
                rawTranscript: 'restored journal entry',
                cleanedText: 'restored journal entry',
                title: 'restored journal entry',
                processingState: ProcessingState.embedded,
                errorMessage: null,
              ),
            ]),
          ),
          onboardingCompleteProvider.overrideWith(
            (_) => _FixedOnboardingNotifier(false),
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

    expect(find.text('restored journal entry'), findsOneWidget);
    expect(find.textContaining('Think out loud. Privately.'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 100));
  });

  testWidgets('LogRow truncates long content on narrow screens', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(240, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final log = VoiceLogView(
      id: 'narrow-log',
      createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
      durationMs: 1234,
      audioPath: 'audio/narrow-log.wav',
      rawTranscript:
          'This is a very long transcript that should wrap or truncate without '
          'causing a RenderFlex overflow in the compact log card.',
      cleanedText: null,
      title:
          'Extremely long generated voice log title that should be ellipsized',
      processingState: ProcessingState.embedded,
      errorMessage: null,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          voiceLogMentionsProvider.overrideWith(
            (ref, logId) => Stream.value([
              const EntityMentionView(
                id: 'mention-1',
                logId: 'narrow-log',
                text:
                    'An extraordinarily long entity mention that must be clipped safely',
                type: 'PROJECT',
                charStart: 0,
                charEnd: 10,
                canonicalEntityId: null,
              ),
            ]),
          ),
        ],
        child: ScreenUtilInit(
          designSize: const Size(440, 956),
          minTextAdapt: true,
          builder: (context, child) => MaterialApp(home: child),
          child: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(12),
              child: LogRow(log: log, onTap: () {}),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(tester.takeException(), isNull);
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

    expect(find.text('VoxSynth.'), findsOneWidget);
    expect(find.textContaining('smarter'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 100));
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
