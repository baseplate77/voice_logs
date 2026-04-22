import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/worker/providers.dart';
import 'features/list/home_list_screen.dart';

/// Root widget of the VoxSynth app.
///
/// Reading [workerProvider] here guarantees the background job worker
/// starts as soon as the app mounts, without a dedicated init screen.
class VoxSynthApp extends ConsumerWidget {
  const VoxSynthApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Force-initialize the worker. Return value unused.
    ref.watch(workerProvider);
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
