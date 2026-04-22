import 'package:flutter/material.dart';

import 'features/list/home_list_screen.dart';

/// Root widget of the VoxSynth app.
///
/// Phase 0 renders a single placeholder screen; feature navigation lands
/// in later phases.
class VoxSynthApp extends StatelessWidget {
  const VoxSynthApp({super.key});

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
