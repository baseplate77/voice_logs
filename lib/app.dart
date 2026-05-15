import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_theme.dart';
import 'core/background_task_bridge.dart';
import 'core/intent_bridge.dart';
import 'core/logger.dart';
import 'core/vox_intent_action.dart';
import 'core/worker/providers.dart';
import 'features/detail/log_detail_screen.dart';
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
  final _navigatorKey = GlobalKey<NavigatorState>();
  final _log = Logger('app');
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
    _intentSub = IntentBridge.actions.listen(_handleIntentAction);
    IntentBridge.initialize();
  }

  void _handleIntentAction(String rawAction) {
    final action = VoxIntentAction.parse(rawAction);
    final state = ref.read(recordingControllerProvider);
    _log.i('intent action="$rawAction" — current state=${state.runtimeType}');
    if (action == null) {
      _log.w('Ignoring unknown intent action: $rawAction');
      return;
    }

    switch (action) {
      case StartRecordingAction():
        _showHome();
        if (state is RecordingIdle || state is RecordingFailed) {
          unawaited(ref.read(recordingControllerProvider.notifier).start());
        }
      case StopRecordingAction():
        _showHome();
        if (state is RecordingActive) {
          unawaited(ref.read(recordingControllerProvider.notifier).stop());
        }
      case OpenVoiceLogAction(:final logId):
        _openVoiceLog(logId);
      case OpenAppAction():
        break;
    }
  }

  void _showHome() {
    final navigator = _navigatorKey.currentState;
    if (navigator == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _showHome();
      });
      return;
    }
    navigator.popUntil((route) => route.isFirst);
  }

  void _openVoiceLog(String logId) {
    final navigator = _navigatorKey.currentState;
    if (navigator == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _openVoiceLog(logId);
      });
      return;
    }
    navigator.push(
      MaterialPageRoute<void>(builder: (_) => LogDetailScreen(logId: logId)),
    );
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
      // Pick up any "start" action queued (or synthesised) by the iOS side
      // — covers Control Widget presses that started a Live Activity in the
      // widget extension process and never reached Flutter through the
      // normal intent dispatch.
      unawaited(IntentBridge.pollPendingActions());
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
      navigatorKey: _navigatorKey,
      title: 'VoxSynth',
      theme: buildVoxTheme(),
      home: const VoxHomeScreen(),
    );
  }
}
