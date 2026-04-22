import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'recording_providers.dart';

/// Recording screen — big record button, elapsed time, transcribing
/// indicator. Live waveform + partial captions arrive in Phase 1.1 when
/// sherpa-onnx's OnlineRecognizer + a streaming model are wired.
class RecordScreen extends ConsumerWidget {
  const RecordScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(recordingControllerProvider);
    final controller = ref.read(recordingControllerProvider.notifier);

    return Scaffold(
      appBar: AppBar(title: const Text('Record')),
      body: Center(
        child: switch (state) {
          RecordingIdle() => _IdleView(onStart: controller.start),
          RecordingActive(:final elapsedMs) => _ActiveView(
            elapsedMs: elapsedMs,
            onStop: controller.stop,
          ),
          RecordingTranscribing() => const _TranscribingView(),
          RecordingFailed(:final message) => _FailedView(
            message: message,
            onRetry: controller.start,
          ),
        },
      ),
    );
  }
}

class _IdleView extends StatelessWidget {
  const _IdleView({required this.onStart});
  final Future<void> Function() onStart;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Text('Tap to start recording', style: TextStyle(fontSize: 18)),
        const SizedBox(height: 32),
        _RoundButton(
          icon: Icons.mic,
          onPressed: () async => onStart(),
          color: Theme.of(context).colorScheme.primary,
        ),
      ],
    );
  }
}

class _ActiveView extends StatelessWidget {
  const _ActiveView({required this.elapsedMs, required this.onStop});
  final int elapsedMs;
  final Future<void> Function() onStop;

  @override
  Widget build(BuildContext context) {
    final seconds = (elapsedMs / 1000).toStringAsFixed(1);
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text('$seconds s', style: const TextStyle(fontSize: 48)),
        const SizedBox(height: 16),
        const Text('Recording…'),
        const SizedBox(height: 32),
        _RoundButton(
          icon: Icons.stop,
          onPressed: () async => onStop(),
          color: Colors.redAccent,
        ),
      ],
    );
  }
}

class _TranscribingView extends StatelessWidget {
  const _TranscribingView();

  @override
  Widget build(BuildContext context) {
    return const Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        CircularProgressIndicator.adaptive(),
        SizedBox(height: 16),
        Text('Transcribing…'),
      ],
    );
  }
}

class _FailedView extends StatelessWidget {
  const _FailedView({required this.message, required this.onRetry});
  final String message;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.error_outline, size: 48, color: Colors.redAccent),
          const SizedBox(height: 16),
          Text(message, textAlign: TextAlign.center),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: () async => onRetry(),
            icon: const Icon(Icons.refresh),
            label: const Text('Try again'),
          ),
        ],
      ),
    );
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({
    required this.icon,
    required this.onPressed,
    required this.color,
  });

  final IconData icon;
  final VoidCallback onPressed;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: color,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onPressed,
        child: SizedBox(
          width: 96,
          height: 96,
          child: Icon(icon, size: 40, color: Colors.white),
        ),
      ),
    );
  }
}
