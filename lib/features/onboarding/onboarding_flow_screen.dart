import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:permission_handler/permission_handler.dart';

import '../home/auto_record_provider.dart';
import '../record/recording_providers.dart';
import 'onboarding_screen_data.dart';
import 'onboarding_visuals.dart';
import 'onboarding_widgets.dart';

/// Main flow screen container that runs the 6-step onboarding process.
class OnboardingFlowScreen extends ConsumerStatefulWidget {
  const OnboardingFlowScreen({super.key});

  @override
  ConsumerState<OnboardingFlowScreen> createState() =>
      _OnboardingFlowScreenState();
}

class _OnboardingFlowScreenState extends ConsumerState<OnboardingFlowScreen> {
  final PageController _pageController = PageController();
  int _currentIndex = 0;

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  Widget _buildVisual(OnboardingVisualType type) {
    switch (type) {
      case OnboardingVisualType.voiceOrb:
        return const VoiceOrbVisual();
      case OnboardingVisualType.privacyDevice:
        return const PrivacyDeviceVisual();
      case OnboardingVisualType.aiPipeline:
        return const AIPipelineVisual();
      case OnboardingVisualType.naturalSearch:
        return const NaturalSearchVisual();
      case OnboardingVisualType.localChat:
        return const LocalChatVisual();
      case OnboardingVisualType.recordButton:
        return const RecordButtonVisual();
    }
  }

  @override
  Widget build(BuildContext context) {
    final bgColor = OnboardingColors.background(context);
    final textSecondary = OnboardingColors.textSecondary(context);
    final screenData = onboardingScreens[_currentIndex];

    return Scaffold(
      backgroundColor: bgColor,
      body: SafeArea(
        child: Column(
          children: [
            // Top action bar (Skip button on screens 1-5)
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 8.h),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  AnimatedOpacity(
                    opacity: _currentIndex < 5 ? 1.0 : 0.0,
                    duration: const Duration(milliseconds: 200),
                    child: IgnorePointer(
                      ignoring: _currentIndex >= 5,
                      child: TextButton(
                        onPressed: () async {
                          await _pageController.animateToPage(
                            5,
                            duration: const Duration(milliseconds: 600),
                            curve: Curves.easeInOutCubic,
                          );
                        },
                        child: Text(
                          'Skip',
                          style: TextStyle(
                            fontFamily: 'JetBrainsMono',
                            fontSize: 13.sp,
                            fontWeight: FontWeight.w600,
                            color: textSecondary,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // Onboarding Pages View
            Expanded(
              child: PageView.builder(
                controller: _pageController,
                itemCount: onboardingScreens.length,
                onPageChanged: (index) {
                  setState(() {
                    _currentIndex = index;
                  });
                },
                itemBuilder: (context, index) {
                  final data = onboardingScreens[index];
                  return OnboardingScreen(
                    data: data,
                    visualWidget: _buildVisual(data.visualType),
                  );
                },
              ),
            ),

            // Bottom Navigation Area
            Padding(
              padding: EdgeInsets.fromLTRB(24.w, 8.h, 24.w, 20.h),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Page Indicators
                  PageIndicator(
                    count: onboardingScreens.length,
                    currentIndex: _currentIndex,
                  ),
                  SizedBox(height: 32.h),

                  // Call To Action (CTA) Button
                  PrimaryButton(
                    label: screenData.ctaText,
                    onPressed: _handleCtaPress,
                  ),

                  // Secondary CTA Button ("Maybe later" on final screen)
                  AnimatedSize(
                    duration: const Duration(milliseconds: 250),
                    curve: Curves.easeInOut,
                    child: _currentIndex == 5
                        ? Padding(
                            padding: EdgeInsets.only(top: 8.h),
                            child: TextButton(
                              onPressed: _handleMaybeLater,
                              child: Text(
                                screenData.secondaryCtaText ?? 'Maybe later',
                                style: TextStyle(
                                  fontSize: 13.sp,
                                  fontWeight: FontWeight.bold,
                                  fontFamily: 'JetBrainsMono',
                                  color: textSecondary,
                                ),
                              ),
                            ),
                          )
                        : const SizedBox.shrink(),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _handleCtaPress() async {
    if (_currentIndex < 5) {
      // Move to next page
      await _pageController.nextPage(
        duration: const Duration(milliseconds: 500),
        curve: Curves.easeInOutCubic,
      );
    } else {
      // Final screen: Request microphone permission
      await _requestPermission();
    }
  }

  Future<void> _handleMaybeLater() async {
    // Save onboarding completed locally but do NOT start recording automatically
    await ref.read(onboardingCompleteProvider.notifier).markComplete();
  }

  Future<void> _requestPermission() async {
    final isSimulator = await _checkSimulator();

    if (isSimulator) {
      // Simulator uses the Mac's mic — OS-level permission is all that matters.
      await ref.read(onboardingCompleteProvider.notifier).markComplete();
      if (!mounted) return;
      await ref.read(recordingControllerProvider.notifier).start();
      return;
    }

    final status = await Permission.microphone.request();
    if (!mounted) return;

    if (status.isGranted) {
      await ref.read(onboardingCompleteProvider.notifier).markComplete();
      await ref.read(recordingControllerProvider.notifier).start();
    } else {
      // Permanently denied or denied - guide user to Settings dialog
      if (!mounted) return;
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
        title: const Text(
          'Microphone required',
          style: TextStyle(
            fontFamily: 'JetBrainsMono',
            fontWeight: FontWeight.bold,
          ),
        ),
        content: const Text(
          'VoxSynth needs microphone access to record your thoughts. '
          'Please enable it in Settings.',
          style: TextStyle(fontFamily: 'JetBrainsMono'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(
              'Cancel',
              style: TextStyle(
                fontFamily: 'JetBrainsMono',
                fontWeight: FontWeight.bold,
                color: OnboardingColors.textSecondary(context),
              ),
            ),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(context).pop();
              openAppSettings();
            },
            child: const Text(
              'Open Settings',
              style: TextStyle(
                fontFamily: 'JetBrainsMono',
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
