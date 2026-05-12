import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/logger.dart';
import '../record/recording_providers.dart';

final _log = Logger('recording_overlay');

/// Displays the current recording state: idle mic button, active timer with
/// stop, transcribing spinner, or error with retry.
class RecordingOverlay extends ConsumerWidget {
  const RecordingOverlay({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(recordingControllerProvider);
    final controller = ref.read(recordingControllerProvider.notifier);
    final theme = Theme.of(context);
    _log.d('build state=${state.runtimeType}');

    return AnimatedSize(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
      child: switch (state) {
        RecordingIdle() => _IdleOverlay(
          onStart: controller.start,
          theme: theme,
        ),
        RecordingActive(:final elapsedMs) => _ActiveOverlay(
          elapsedMs: elapsedMs,
          onStop: controller.stop,
          theme: theme,
        ),
        RecordingTranscribing() => _TranscribingOverlay(theme: theme),
        RecordingFailed(:final message) => _FailedOverlay(
          message: message,
          onRetry: controller.start,
          theme: theme,
        ),
      },
    );
  }
}

class _IdleOverlay extends StatelessWidget {
  const _IdleOverlay({required this.onStart, required this.theme});
  final Future<void> Function() onStart;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Tap to record',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 16),
          _RecordButton(
            icon: Icons.mic,
            onPressed: () async => onStart(),
            color: theme.colorScheme.primary,
          ),
        ],
      ),
    );
  }
}

class _ActiveOverlay extends StatelessWidget {
  const _ActiveOverlay({
    required this.elapsedMs,
    required this.onStop,
    required this.theme,
  });
  final int elapsedMs;
  final Future<void> Function() onStop;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    final minutes = (elapsedMs ~/ 60000).toString().padLeft(2, '0');
    final seconds = ((elapsedMs ~/ 1000) % 60).toString().padLeft(2, '0');
    return Container(
      width: double.infinity,
      color: Colors.redAccent.withValues(alpha: 0.08),
      padding: const EdgeInsets.symmetric(vertical: 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const _PulsingDot(),
              const SizedBox(width: 8),
              Text(
                'Recording',
                style: theme.textTheme.labelLarge?.copyWith(
                  color: Colors.redAccent,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            '$minutes:$seconds',
            style: theme.textTheme.displayMedium?.copyWith(
              fontFeatures: [const FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(height: 24),
          _RecordButton(
            icon: Icons.stop_rounded,
            onPressed: () async => onStop(),
            color: Colors.redAccent,
          ),
        ],
      ),
    );
  }
}

class _TranscribingOverlay extends StatelessWidget {
  const _TranscribingOverlay({required this.theme});
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 32,
            height: 32,
            child: CircularProgressIndicator.adaptive(strokeWidth: 3),
          ),
          const SizedBox(height: 16),
          Text('Transcribing...', style: theme.textTheme.titleMedium),
        ],
      ),
    );
  }
}

class _FailedOverlay extends StatelessWidget {
  const _FailedOverlay({
    required this.message,
    required this.onRetry,
    required this.theme,
  });
  final String message;
  final Future<void> Function() onRetry;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline, size: 40, color: Colors.redAccent),
          const SizedBox(height: 12),
          Text(
            message,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 16),
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

class _PulsingDot extends StatefulWidget {
  const _PulsingDot();

  @override
  State<_PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<_PulsingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween<double>(begin: 0.3, end: 1.0).animate(_controller),
      child: Container(
        width: 12,
        height: 12,
        decoration: const BoxDecoration(
          color: Colors.redAccent,
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}

class _RecordButton extends StatelessWidget {
  const _RecordButton({
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
      elevation: 4,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onPressed,
        child: SizedBox(
          width: 80,
          height: 80,
          child: Icon(icon, size: 36, color: Colors.white),
        ),
      ),
    );
  }
}
