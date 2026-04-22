import 'package:flutter/material.dart';

/// Reverse-chronological list of voice logs. Phase 0 scaffold — empty state
/// only; real rows arrive in Phase 1 once recording is wired.
class HomeListScreen extends StatelessWidget {
  const HomeListScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('VoxSynth')),
      body: const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Your journal gets smarter as you record more.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 18),
          ),
        ),
      ),
    );
  }
}
