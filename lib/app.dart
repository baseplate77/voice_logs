import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/worker/providers.dart';
import 'features/list/home_list_screen.dart';

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
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(workerProvider).start();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Idempotent. On a fresh process this recovers `running` jobs from SQL;
      // on a warm resume it makes sure polling is active again.
      unawaited(ref.read(workerProvider).start());
      return;
    }
    // Release heavyweight model memory when app leaves foreground.
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      unawaited(ref.read(llmRunnerProvider).unload());
    }
  }

  @override
  void didHaveMemoryPressure() {
    unawaited(ref.read(llmRunnerProvider).unload());
  }

  @override
  void dispose() {
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
      home: const HomeListScreen(),
    );
  }
}
