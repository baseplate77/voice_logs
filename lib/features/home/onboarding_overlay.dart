import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../record/recording_providers.dart';
import 'auto_record_provider.dart';

/// First-launch overlay that explains auto-record and requests mic permission.
class OnboardingOverlay extends ConsumerWidget {
  const OnboardingOverlay({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.mic_none_rounded,
              size: 72,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(height: 24),
            Text('VoxSynth', style: theme.textTheme.headlineMedium),
            const SizedBox(height: 12),
            Text(
              'Recording starts automatically when you open the app. '
              'Your voice stays on this device — always.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyLarge,
            ),
            const SizedBox(height: 32),
            FilledButton.icon(
              onPressed: () => _requestPermission(context, ref),
              icon: const Icon(Icons.mic),
              label: const Text('Get started'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _requestPermission(BuildContext context, WidgetRef ref) async {
    final isSimulator = await _checkSimulator();

    if (isSimulator) {
      // Simulator uses the Mac's mic — OS-level permission is all that matters.
      await ref.read(onboardingCompleteProvider.notifier).markComplete();
      if (!context.mounted) return;
      await ref.read(recordingControllerProvider.notifier).start();
      return;
    }

    final status = await Permission.microphone.request();
    if (!context.mounted) return;

    if (status.isGranted) {
      await ref.read(onboardingCompleteProvider.notifier).markComplete();
      await ref.read(recordingControllerProvider.notifier).start();
    } else if (status.isPermanentlyDenied) {
      _showSettingsDialog(context);
    } else {
      // .denied or .restricted — prompt again.
      _showSettingsDialog(context);
    }
  }

  static Future<bool> _checkSimulator() async {
    try {
      const channel = MethodChannel('com.nj.voxsynth/runtime');
      return await channel.invokeMethod<bool>('isIosSimulator') ?? false;
    } on MissingPluginException {
      return false;
    }
  }

  void _showSettingsDialog(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Microphone required'),
        content: const Text(
          'VoxSynth needs microphone access to record. '
          'Please enable it in Settings.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(context).pop();
              openAppSettings();
            },
            child: const Text('Open Settings'),
          ),
        ],
      ),
    );
  }
}
