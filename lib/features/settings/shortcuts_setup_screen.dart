import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

/// Guides users through setting up system shortcuts that launch VoxSynth
/// and start recording. Each entry point links to the relevant iOS Settings
/// path or explains the setup steps.
class ShortcutsSetupScreen extends StatelessWidget {
  const ShortcutsSetupScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Quick Access')),
      body: ListView(
        children: [
          _SectionHeader(title: 'Voice shortcuts', theme: theme),
          const _ShortcutTile(
            icon: Icons.mic_external_on,
            title: 'Siri',
            subtitle: '"Hey Siri, start voice log"',
            steps: [
              'Works automatically after installing VoxSynth.',
              'Say "Hey Siri, start voice log" or "Hey Siri, record in VoxSynth".',
              'VoxSynth opens and recording begins immediately.',
            ],
          ),
          Divider(height: 1.h),
          _SectionHeader(title: 'Hardware buttons', theme: theme),
          const _ShortcutTile(
            icon: Icons.touch_app,
            title: 'Action Button',
            subtitle: 'iPhone 15 Pro and later',
            steps: [
              'Open Settings → Action Button.',
              'Select "Shortcut".',
              'Search for "Start Voice Log".',
              'Press the Action Button to open VoxSynth and start recording.',
            ],
          ),
          Divider(height: 1.h),
          const _ShortcutTile(
            icon: Icons.back_hand_outlined,
            title: 'Back Tap',
            subtitle: 'Double or triple tap the back of your iPhone',
            steps: [
              'Open Settings → Accessibility → Touch → Back Tap.',
              'Choose Double Tap or Triple Tap.',
              'Select "Shortcut" → "Start Voice Log".',
              'Tap the back of your iPhone to start recording.',
            ],
          ),
          Divider(height: 1.h),
          _SectionHeader(title: 'Lock Screen & Control Center', theme: theme),
          if (Platform.isIOS)
            const _ShortcutTile(
              icon: Icons.lock_outline,
              title: 'Lock Screen',
              subtitle: 'iOS 18+: native control. iOS 16-17: Shortcuts widget.',
              steps: [
                'iOS 18+: Long-press Lock Screen → Customize → tap a control slot → search "VoxSynth".',
                'iOS 16-17: Add the Shortcuts widget to your Lock Screen, then place the "Start Voice Log" shortcut in it.',
              ],
            ),
          Divider(height: 1.h),
          const _ShortcutTile(
            icon: Icons.control_camera,
            title: 'Control Center',
            subtitle: 'iOS 18+ only',
            steps: [
              'Open Settings → Control Center.',
              'Tap the "+" next to "Start Voice Log" under VoxSynth.',
              'Swipe down from the top-right to access it anytime.',
            ],
          ),
          Divider(height: 1.h),
          _SectionHeader(title: 'How it works', theme: theme),
          Padding(
            padding: EdgeInsets.all(16.r),
            child: Text(
              'Every shortcut opens VoxSynth and starts recording immediately. '
              'When you stop, the recording is transcribed on-device, then '
              'refined, embedded, and added to your memory — all locally, '
              'even if the app goes to the background.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, required this.theme});
  final String title;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
      child: Text(
        title.toUpperCase(),
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          letterSpacing: 1.2,
        ),
      ),
    );
  }
}

class _ShortcutTile extends StatelessWidget {
  const _ShortcutTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.steps,
  });
  final IconData icon;
  final String title;
  final String subtitle;
  final List<String> steps;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ExpansionTile(
      leading: Icon(icon, color: theme.colorScheme.primary),
      title: Text(title),
      subtitle: Text(
        subtitle,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var i = 0; i < steps.length; i++)
                Padding(
                  padding: EdgeInsets.only(bottom: 8.h),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 24.w,
                        child: Text(
                          '${i + 1}.',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                            color: theme.colorScheme.primary,
                          ),
                        ),
                      ),
                      Expanded(
                        child: Text(
                          steps[i],
                          style: theme.textTheme.bodyMedium,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
