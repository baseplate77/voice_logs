import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/background_task_bridge.dart';
import 'core/intent_bridge.dart';
import 'core/worker/providers.dart';
import 'features/home/vox_home_screen.dart';
import 'features/record/recording_providers.dart';

/// Root widget of the VoxSynth app.
///
/// Starts the background job worker after the first frame so plugin
/// channels (notably `path_provider_android` → `jni`) are fully attached
/// before any DB access happens.
class VoxSynthApp extends ConsumerStatefulWidget {
  const VoxSynthApp({super.key});

  @override
  ConsumerState<VoxSynthApp> createState() => _VoxSynthAppState();
}

class _VoxSynthAppState extends ConsumerState<VoxSynthApp>
    with WidgetsBindingObserver {
  StreamSubscription<String>? _intentSub;
  StreamSubscription<void>? _backgroundTaskSub;
  bool _completingBackgroundTask = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(workerProvider).start();
      _listenForIntents();
      _listenForBackgroundProcessingTasks();
      unawaited(_syncScheduledProcessingTask());
    });
  }

  void _listenForIntents() {
    IntentBridge.initialize();
    _intentSub = IntentBridge.actions.listen((action) {
      final controller = ref.read(recordingControllerProvider.notifier);
      final state = ref.read(recordingControllerProvider);
      switch (action) {
        case 'start':
          if (state is RecordingIdle || state is RecordingFailed) {
            controller.start();
          }
        case 'stop':
          if (state is RecordingActive) {
            controller.stop();
          }
      }
    });
  }

  void _listenForBackgroundProcessingTasks() {
    BackgroundTaskBridge.initialize();
    _backgroundTaskSub = BackgroundTaskBridge.processingTasks.listen((_) {
      unawaited(_completeBackgroundProcessingTaskWhenIdle());
    });
  }

  Future<void> _completeBackgroundProcessingTaskWhenIdle() async {
    if (_completingBackgroundTask) return;
    _completingBackgroundTask = true;
    var success = false;
    try {
      await ref.read(workerProvider).start();
      final queue = ref.read(jobQueueProvider);
      final deadline = DateTime.now().add(const Duration(minutes: 25));
      while (mounted && DateTime.now().isBefore(deadline)) {
        if (!await queue.hasActiveJobs()) {
          success = true;
          await BackgroundTaskBridge.cancelProcessingTask();
          return;
        }
        await Future<void>.delayed(const Duration(seconds: 2));
      }
      await BackgroundTaskBridge.scheduleProcessingTask(
        earliestBegin: const Duration(minutes: 5),
      );
    } finally {
      await BackgroundTaskBridge.completeProcessingTask(success: success);
      _completingBackgroundTask = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Idempotent. On a fresh process this recovers `running` jobs from SQL;
      // on a warm resume it makes sure polling is active again.
      unawaited(ref.read(workerProvider).start());
      unawaited(_syncScheduledProcessingTask());
      return;
    }
    // Release heavyweight model memory when app leaves foreground,
    // but only if no pipeline jobs are pending — otherwise the worker
    // needs the LLM to complete refine/memory jobs in the background.
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      _syncBackgroundPlanAndUnloadIfIdle();
    }
  }

  Future<void> _syncScheduledProcessingTask() async {
    final queue = ref.read(jobQueueProvider);
    final hasJobs = await queue.hasActiveJobs();
    if (hasJobs) {
      await BackgroundTaskBridge.scheduleProcessingTask();
    } else {
      await BackgroundTaskBridge.cancelProcessingTask();
    }
  }

  Future<void> _syncBackgroundPlanAndUnloadIfIdle() async {
    final queue = ref.read(jobQueueProvider);
    final hasJobs = await queue.hasActiveJobs();
    if (hasJobs) {
      await BackgroundTaskBridge.scheduleProcessingTask();
    } else {
      await BackgroundTaskBridge.cancelProcessingTask();
      await ref.read(llmRunnerProvider).unload();
    }
  }

  @override
  void didHaveMemoryPressure() {
    unawaited(ref.read(llmRunnerProvider).unload());
  }

  @override
  void dispose() {
    _intentSub?.cancel();
    _backgroundTaskSub?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'VoxSynth',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
      ),
      home: const VoxHomeScreen(),
    );
  }
}
