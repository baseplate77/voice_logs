import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/db/providers.dart';
import '../actions/action_screen.dart';
import '../ask/ask_screen.dart';
import '../debug/pipeline_debug_screen.dart';
import '../detail/log_detail_screen.dart';
import '../list/log_row.dart';
import '../record/recording_providers.dart';
import '../search/search_screen.dart';
import '../settings/settings_screen.dart';
import 'auto_record_provider.dart';
import 'onboarding_overlay.dart';
import 'recording_overlay.dart';
import 'two_tone_palette.dart';

/// Primary screen: recording overlay at the top, log list below.
///
/// On cold launch with auto-record enabled, recording starts automatically
/// after the first frame. First launch shows an onboarding overlay instead
/// that requests microphone permission.
class VoxHomeScreen extends ConsumerStatefulWidget {
  const VoxHomeScreen({super.key});

  @override
  ConsumerState<VoxHomeScreen> createState() => _VoxHomeScreenState();
}

class _VoxHomeScreenState extends ConsumerState<VoxHomeScreen> {
  bool _autoRecordFired = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _maybeAutoRecord();
    });
  }

  void _maybeAutoRecord() {
    if (_autoRecordFired) return;
    _autoRecordFired = true;

    final onboarding = ref.read(onboardingCompleteProvider);
    final isComplete = onboarding.valueOrNull ?? false;
    if (!isComplete) return;

    final autoEnabled = ref.read(autoRecordEnabledProvider);
    if (!autoEnabled) return;

    final state = ref.read(recordingControllerProvider);
    if (state is RecordingIdle) {
      ref.read(recordingControllerProvider.notifier).start();
    }
  }

  @override
  Widget build(BuildContext context) {
    final onboarding = ref.watch(onboardingCompleteProvider);
    final isOnboarded = onboarding.valueOrNull ?? false;
    final logs = ref.watch(voiceLogsStreamProvider);
    final hasImportedLogs = logs.valueOrNull?.isNotEmpty ?? false;

    return Scaffold(
      backgroundColor: TwoTonePalette.canvas,
      appBar: AppBar(
        backgroundColor: TwoTonePalette.canvas,
        elevation: 0,
        scrolledUnderElevation: 0,
        foregroundColor: TwoTonePalette.fgPrimary,
        title: const Text('VoxSynth'),
        actions: [
          IconButton(
            tooltip: 'Pipeline debug',
            icon: const Icon(Icons.bug_report_outlined),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const PipelineDebugScreen(),
              ),
            ),
          ),
          IconButton(
            tooltip: 'Ask',
            icon: const Icon(Icons.question_answer_outlined),
            onPressed: () => Navigator.of(
              context,
            ).push(MaterialPageRoute<void>(builder: (_) => const AskScreen())),
          ),
          IconButton(
            tooltip: 'Action Inbox',
            icon: const Icon(Icons.check_circle_outline),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const ActionScreen()),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.search),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const SearchScreen()),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const SettingsScreen()),
            ),
          ),
        ],
      ),
      body: isOnboarded || hasImportedLogs
          ? const _MainContent()
          : const OnboardingOverlay(),
    );
  }
}

class _MainContent extends ConsumerWidget {
  const _MainContent();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final logs = ref.watch(voiceLogsStreamProvider);
    final recordingState = ref.watch(recordingControllerProvider);
    final isRecording =
        recordingState is RecordingActive ||
        recordingState is RecordingTranscribing;

    // Gradient fade sits over the bottom of the scrollable list so log
    // content visibly dissolves into the recording zone below — softer
    // than a hairline divider on white-on-white.
    return Column(
      children: [
        Expanded(
          child: Stack(
            children: [
              Positioned.fill(
                child: ColoredBox(
                  color: TwoTonePalette.canvas,
                  child: AnimatedOpacity(
                    duration: const Duration(milliseconds: 200),
                    opacity: isRecording ? 0.55 : 1.0,
                    child: logs.when(
                      data: (rows) {
                        if (rows.isEmpty) return const _EmptyState();
                        return ListView.separated(
                          padding: const EdgeInsets.only(bottom: 32),
                          itemCount: rows.length,
                          separatorBuilder: (_, _) => const Divider(
                            height: 1,
                            color: TwoTonePalette.slabOnLight,
                          ),
                          itemBuilder: (_, i) {
                            final row = rows[i];
                            return LogRow(
                              log: row,
                              onTap: () => Navigator.of(context).push(
                                MaterialPageRoute<void>(
                                  builder: (_) =>
                                      LogDetailScreen(logId: row.id),
                                ),
                              ),
                            );
                          },
                        );
                      },
                      loading: () => const Center(
                        child: CircularProgressIndicator.adaptive(),
                      ),
                      error: (e, _) => Center(child: Text('Error: $e')),
                    ),
                  ),
                ),
              ),
              const Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                height: 40,
                child: IgnorePointer(child: _ScrollFadeEdge()),
              ),
            ],
          ),
        ),
        const RecordingOverlay(),
      ],
    );
  }
}

/// Soft top→bottom gradient covering the last 40px of the list zone.
/// Pinned above the recording overlay so log rows scroll up out of view
/// behind it, dissolving into the canvas instead of meeting a hard edge.
class _ScrollFadeEdge extends StatelessWidget {
  const _ScrollFadeEdge();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            TwoTonePalette.canvas.withValues(alpha: 0),
            TwoTonePalette.canvas,
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(24),
        child: Text(
          'Your journal gets smarter as you record more.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 18),
        ),
      ),
    );
  }
}
