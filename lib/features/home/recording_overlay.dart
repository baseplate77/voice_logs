import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:iconsax/iconsax.dart';

import '../../app_theme.dart';
import '../../core/logger.dart';
import '../ask/ask_screen.dart';
import '../record/record_screen.dart';
import '../record/recording_providers.dart';
import '../record/transcribing_indicator.dart';
import '../settings/settings_screen.dart';

final _log = Logger('recording_overlay');

/// The bottom navigation deck containing stateful control actions.
/// Designed to sit on top of the black canvas exposed under the lifted home screen panel.
class RecordingOverlay extends ConsumerWidget {
  const RecordingOverlay({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(recordingControllerProvider);
    final controller = ref.read(recordingControllerProvider.notifier);
    _log.d('build state=${state.runtimeType}');

    final double bottomPadding = MediaQuery.paddingOf(context).bottom;
    final double barHeight =
        58.0.h + bottomPadding; // Reduced base height to 58.0

    return SizedBox(
      height: barHeight,
      width: double.infinity,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // Content aligned within the 64px zone, leaving safe area spacing below
          Positioned(
            left: 0.w,
            right: 0.w,
            top: 0.h,
            height: 58.h,
            child: AnimatedSize(
              duration: const Duration(milliseconds: 240),
              curve: Curves.easeOut,
              child: switch (state) {
                RecordingIdle() => _IdleDeck(
                  onStart: () {
                    unawaited(controller.start());
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const RecordScreen(),
                      ),
                    );
                  },
                ),
                RecordingActive(:final elapsedMs) => _ActiveDeck(
                  elapsedMs: elapsedMs,
                  onStop: controller.stop,
                ),
                RecordingTranscribing() => const _TranscribingDeck(),
                RecordingFailed(:final message) => _FailedDeck(
                  message: message,
                  onRetry: controller.start,
                ),
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// Symmetrical large tactile circular button frame with outer white ring and black base.
class _LargeRecordButton extends StatelessWidget {
  const _LargeRecordButton({required this.onPressed, required this.child});
  final VoidCallback onPressed;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onPressed,
      customBorder: const CircleBorder(),
      child: Container(
        width: 95.r,
        height: 95.r,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.transparent,
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.95),
            width: 1.5.r,
          ),
        ),
        padding: EdgeInsets.all(9.r),
        child: child,
      ),
    );
  }
}

/// Idle deck: home icon on left, settings icon on right, and massive record button.
class _IdleDeck extends StatelessWidget {
  const _IdleDeck({required this.onStart});
  final VoidCallback onStart;

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        // Sidebar Navigation Actions - lowered using top: 12 padding
        Positioned.fill(
          child: Padding(
            padding: EdgeInsets.only(left: 36.w, right: 36.w, top: 12.h),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: Icon(
                        Iconsax.message_text,
                        color: Colors.white,
                        size: 26.r,
                      ),
                      tooltip: 'Chat',
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const AskScreen(),
                        ),
                      ),
                    ),
                  ],
                ),
                IconButton(
                  icon: Icon(
                    Iconsax.setting_2,
                    color: Colors.white,
                    size: 26.r,
                  ),
                  tooltip: 'Settings',
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const SettingsScreen(),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        // Symmetrical large tactile Record Button sitting precisely inside the scoop
        Positioned(
          top: -46.h, // Adjusted top position for 58px bar height
          left: 0.w,
          right: 0.w,
          child: Center(
            child: _LargeRecordButton(
              onPressed: onStart,
              child: Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.5),
                      blurRadius: 4.r,
                      offset: Offset(0.w, 3.h),
                    ),
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.25),
                      blurRadius: 8.r,
                      offset: Offset(0.w, 1.h),
                    ),
                  ],
                  gradient: const RadialGradient(
                    center: Alignment(-0.25, -0.25),
                    radius: 0.85,
                    colors: [
                      Color(0xFFFF3B30),
                      Color(0xFFC71C1C),
                      Color(0xFF800606),
                    ],
                    stops: [0.0, 0.75, 1.0],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Active deck: pulsing dot and status on left, timer on right, and stop button.
class _ActiveDeck extends StatelessWidget {
  const _ActiveDeck({required this.elapsedMs, required this.onStop});
  final int elapsedMs;
  final Future<void> Function() onStop;

  @override
  Widget build(BuildContext context) {
    final minutes = (elapsedMs ~/ 60000).toString().padLeft(2, '0');
    final seconds = ((elapsedMs ~/ 1000) % 60).toString().padLeft(2, '0');

    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned.fill(
          child: Padding(
            padding: EdgeInsets.only(left: 36.w, right: 36.w, top: 12.h),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const _PulsingDot(),
                    SizedBox(width: 8.w),
                    Text(
                      'REC',
                      style: TextStyle(
                        fontSize: 12.sp,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 1.5,
                        color: VoxAppColors.accent,
                      ),
                    ),
                  ],
                ),
                Text(
                  '$minutes:$seconds',
                  style: TextStyle(
                    fontSize: 15.sp,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                    fontFamily: 'IBMPlexMono',
                  ),
                ),
              ],
            ),
          ),
        ),
        // Stop button nested inside the scoop
        Positioned(
          top: -46.h,
          left: 0.w,
          right: 0.w,
          child: Center(
            child: _LargeRecordButton(
              onPressed: () async => onStop(),
              child: Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.5),
                      blurRadius: 4.r,
                      offset: Offset(0.w, 3.h),
                    ),
                  ],
                  gradient: const RadialGradient(
                    center: Alignment(-0.25, -0.25),
                    radius: 0.85,
                    colors: [
                      Color(0xFFFF3B30), // bright retro red
                      Color(0xFFC71C1C), // deep red
                      Color(0xFF800606), // darker red for shadowy median effect
                    ],
                    stops: [0.0, 0.75, 1.0],
                  ),
                ),
                child: Center(
                  child: Container(
                    width: 20.r,
                    height: 20.r,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(4.r),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.3),
                          blurRadius: 2.r,
                          offset: Offset(0.w, 1.h),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Transcribing deck: loading labels flanking a transcribing spinner in the scoop.
class _TranscribingDeck extends StatelessWidget {
  const _TranscribingDeck();

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned.fill(
          child: Padding(
            padding: EdgeInsets.only(left: 36.w, right: 36.w, top: 12.h),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'VOXSYNTH',
                  style: TextStyle(
                    fontSize: 12.sp,
                    fontWeight: FontWeight.bold,
                    color: Colors.white54,
                    letterSpacing: 2.0,
                    fontFamily: 'IBMPlexMono',
                  ),
                ),
                Text(
                  'PROCESSING...',
                  style: TextStyle(
                    fontSize: 12.sp,
                    fontWeight: FontWeight.bold,
                    color: Colors.white54,
                    letterSpacing: 1.0,
                    fontFamily: 'IBMPlexMono',
                  ),
                ),
              ],
            ),
          ),
        ),
        // Transcribing indicator in the scoop
        Positioned(
          top: -46.h,
          left: 0.w,
          right: 0.w,
          child: Center(
            child: _LargeRecordButton(
              onPressed: () {},
              child: Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: const Color(0xFF1E1F22),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.3),
                      blurRadius: 4.r,
                      offset: Offset(0.w, 2.h),
                    ),
                  ],
                ),
                child: Center(
                  child: TranscribingIndicator(size: 24.r, color: Colors.white),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Failed deck: error message on the left, retry button in the scoop.
class _FailedDeck extends StatelessWidget {
  const _FailedDeck({required this.message, required this.onRetry});
  final String message;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned.fill(
          child: Padding(
            padding: EdgeInsets.only(left: 24.w, right: 90.w, top: 12.h),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                message,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: Colors.redAccent,
                  fontSize: 12.sp,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ),
        // Retry circular button inside the scoop
        Positioned(
          top: -46.h,
          left: 0.w,
          right: 0.w,
          child: Center(
            child: _LargeRecordButton(
              onPressed: () async => onRetry(),
              child: Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.5),
                      blurRadius: 4.r,
                      offset: Offset(0.w, 3.h),
                    ),
                  ],
                  gradient: const RadialGradient(
                    center: Alignment(-0.25, -0.25),
                    radius: 0.85,
                    colors: [
                      Color(0xFFFF3B30),
                      Color(0xFFC71C1C),
                      Color(0xFF800606),
                    ],
                    stops: [0.0, 0.75, 1.0],
                  ),
                ),
                child: Icon(
                  Icons.refresh_rounded,
                  color: Colors.white,
                  size: 26.r,
                ),
              ),
            ),
          ),
        ),
      ],
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
        width: 8.r,
        height: 8.r,
        decoration: const BoxDecoration(
          color: VoxAppColors.accent,
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}
