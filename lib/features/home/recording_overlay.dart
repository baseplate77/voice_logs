import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/logger.dart';
import '../record/recording_providers.dart';
import '../record/transcribing_indicator.dart';
import 'two_tone_palette.dart';

final _log = Logger('recording_overlay');

/// The recording surface at the bottom of the home screen. Renders the
/// current recording state in one of four shapes: idle mic, active timer
/// + stop, transcribing spinner, or failed retry. Painted on the white
/// canvas with orchid primary actions.
class RecordingOverlay extends ConsumerWidget {
  const RecordingOverlay({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(recordingControllerProvider);
    final controller = ref.read(recordingControllerProvider.notifier);
    _log.d('build state=${state.runtimeType}');

    // Full-bleed canvas: the gradient fade above this zone lives on the
    // scrolling list so log content visibly fades as it scrolls down,
    // rather than being clipped by a hard divider.
    return SizedBox(
      width: double.infinity,
      child: ColoredBox(
        color: TwoTonePalette.canvas,
        child: SafeArea(
          top: false,
          child: AnimatedSize(
            duration: const Duration(milliseconds: 280),
            curve: Curves.easeOut,
            child: switch (state) {
              RecordingIdle() => _IdleOverlay(onStart: controller.start),
              RecordingActive(:final elapsedMs) => _ActiveOverlay(
                elapsedMs: elapsedMs,
                onStop: controller.stop,
              ),
              RecordingTranscribing() => const _TranscribingOverlay(),
              RecordingFailed(:final message) => _FailedOverlay(
                message: message,
                onRetry: controller.start,
              ),
            },
          ),
        ),
      ),
    );
  }
}

class _IdleOverlay extends StatelessWidget {
  const _IdleOverlay({required this.onStart});
  final Future<void> Function() onStart;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 28, 24, 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('TAP TO RECORD', style: labelCaps(TwoTonePalette.fgMuted)),
          const SizedBox(height: 20),
          _PrimarySquareButton(
            icon: Icons.mic_rounded,
            onPressed: () async => onStart(),
          ),
        ],
      ),
    );
  }
}

class _ActiveOverlay extends StatelessWidget {
  const _ActiveOverlay({required this.elapsedMs, required this.onStop});
  final int elapsedMs;
  final Future<void> Function() onStop;

  @override
  Widget build(BuildContext context) {
    final minutes = (elapsedMs ~/ 60000).toString().padLeft(2, '0');
    final seconds = ((elapsedMs ~/ 1000) % 60).toString().padLeft(2, '0');
    final centi = ((elapsedMs ~/ 10) % 100).toString().padLeft(2, '0');
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 28, 24, 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const _PulsingDot(),
              const SizedBox(width: 8),
              Text('RECORDING', style: labelCaps(TwoTonePalette.accentRed)),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            '$minutes:$seconds:$centi',
            style: const TextStyle(
              fontSize: 56,
              fontWeight: FontWeight.w700,
              letterSpacing: -1.5,
              color: TwoTonePalette.fgPrimary,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(height: 22),
          _PrimarySquareButton(
            icon: Icons.stop_rounded,
            onPressed: () async => onStop(),
          ),
        ],
      ),
    );
  }
}

class _TranscribingOverlay extends StatelessWidget {
  const _TranscribingOverlay();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const TranscribingIndicator(),
          const SizedBox(height: 14),
          Text('TRANSCRIBING', style: labelCaps(TwoTonePalette.fgPrimary)),
        ],
      ),
    );
  }
}

class _FailedOverlay extends StatelessWidget {
  const _FailedOverlay({required this.message, required this.onRetry});
  final String message;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.error_outline,
            size: 36,
            color: TwoTonePalette.accentRed,
          ),
          const SizedBox(height: 10),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: TwoTonePalette.fgPrimary,
              fontSize: 14,
            ),
          ),
          const SizedBox(height: 16),
          _PrimarySquareButton(
            icon: Icons.refresh_rounded,
            onPressed: () async => onRetry(),
            label: 'TRY AGAIN',
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
        width: 10,
        height: 10,
        decoration: const BoxDecoration(
          color: TwoTonePalette.accentRed,
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}

/// Editorial square button matching the primary call-to-action.
/// 88×88 with 20pt corner radius per `docs/design_future_two_tone.md`.
class _PrimarySquareButton extends StatelessWidget {
  const _PrimarySquareButton({
    required this.icon,
    required this.onPressed,
    this.label,
  });

  final IconData icon;
  final VoidCallback onPressed;

  /// Optional small-caps label shown under the glyph. Used for the retry
  /// affordance where the icon alone is ambiguous.
  final String? label;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: TwoTonePalette.accentRed,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(20),
        child: SizedBox(
          width: 88,
          height: 88,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 36, color: TwoTonePalette.fgOnSlab),
              if (label != null) ...[
                const SizedBox(height: 4),
                Text(label!, style: labelCaps(TwoTonePalette.fgOnSlab)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
