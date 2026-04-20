import 'package:flutter/material.dart';

import 'ui/debug/debug_home_screen.dart';

/// Root widget. Currently renders the debug screen — a one-pane view of
/// the capture → ASR → cleanup → embed → store pipeline — so the native
/// integration can be eyeballed end-to-end on device.
class VoxSynthApp extends StatelessWidget {
  const VoxSynthApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'VoxSynth',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      home: const DebugHomeScreen(),
    );
  }
}
