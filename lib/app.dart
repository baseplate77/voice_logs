import 'package:flutter/material.dart';

/// Root widget. Placeholder until Phase 1+ land a real UI under `lib/ui/`.
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
      home: const _BootstrapHome(),
    );
  }
}

class _BootstrapHome extends StatelessWidget {
  const _BootstrapHome();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('VoxSynth')),
      body: const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Phase 3 complete. Libraries landed:\n'
            '• Capture + VAD\n'
            '• Parakeet-TDT ASR (Rust + sherpa-onnx)\n'
            '• Gemma 3 1B IT + cleanup pipeline (Rust + candle)\n\n'
            'No UI yet — drive services programmatically.',
            textAlign: TextAlign.center,
          ),
        ),
      ),
    );
  }
}
