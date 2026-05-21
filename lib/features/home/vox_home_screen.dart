import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../app_theme.dart';
import '../../core/db/providers.dart';
import '../detail/log_detail_screen.dart';
import '../garden/vox_garden_screen.dart';
import '../list/log_row.dart';
import '../record/recording_providers.dart';
import '../search/search_screen.dart';
import 'auto_record_provider.dart';
import 'onboarding_overlay.dart';
import 'recording_overlay.dart';
import 'two_tone_palette.dart';

/// Primary screen: stateful dashboard.
/// Renders a premium physical layout: a deep dark base board over which a
/// custom-clipped warm off-white faceplate sits, revealing the bottom navigation
/// deck and record button cove below.
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

    // Use dark console background if onboarded or logs exist, showing our physical deck
    return Scaffold(
      backgroundColor: (isOnboarded || hasImportedLogs)
          ? const Color(0xFF121315)
          : TwoTonePalette.canvas,
      body: isOnboarded || hasImportedLogs
          ? const _MainContent()
          : const SafeArea(child: OnboardingOverlay()),
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

    final double bottomPadding = MediaQuery.paddingOf(context).bottom;
    final double navBarHeight =
        58.0.h + bottomPadding; // Reduced to 58.0 base height

    return Stack(
      clipBehavior: Clip.none,
      children: [
        // 1. Sleek physical dark console background
        Positioned.fill(child: Container(color: const Color(0xFF121315))),

        // 2. White Canvas Panel (light-themed dashboard plate)
        Positioned.fill(
          child: ClipPath(
            clipper: _WhiteCanvasClipper(bottomNavBarHeight: navBarHeight),
            child: Container(
              color: TwoTonePalette.canvas, // warm off-white #F4F4F4
              child: SafeArea(
                bottom: false,
                child: Padding(
                  padding: EdgeInsets.fromLTRB(20.w, 20.h, 20.w, 0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Header Title
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text.rich(
                            TextSpan(
                              children: [
                                TextSpan(
                                  text: 'VoxSynth',
                                  style: TextStyle(
                                    fontSize: 28.sp,
                                    fontFamily: 'NDot',
                                    color: VoxAppColors.primary,
                                  ),
                                ),
                                TextSpan(
                                  text: '.',
                                  style: TextStyle(
                                    fontSize: 28.sp,
                                    fontFamily: 'NDot',
                                    color: VoxAppColors.accent,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            style: IconButton.styleFrom(
                              backgroundColor: Colors.white,
                              side: const BorderSide(color: VoxAppColors.outline),
                            ),
                            icon: const Icon(Icons.yard_outlined, color: VoxAppColors.primary),
                            tooltip: 'Synthia Garden',
                            onPressed: () => Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) => const VoxGardenScreen(),
                              ),
                            ),
                          ),
                        ],
                      ),
                      SizedBox(height: 20.h),
                      // Search Bar + Filter Button
                      Row(
                        children: [
                          Expanded(
                            child: InkWell(
                              onTap: () => Navigator.of(context).push(
                                MaterialPageRoute<void>(
                                  builder: (_) => const SearchScreen(),
                                ),
                              ),
                              borderRadius: BorderRadius.circular(12.r),
                              child: Container(
                                padding: EdgeInsets.symmetric(
                                  horizontal: 14.w,
                                  vertical: 12.h,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(12.r),
                                  border: Border.all(
                                    color: VoxAppColors.outline,
                                  ),
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black.withValues(
                                        alpha: 0.03,
                                      ),
                                      blurRadius: 4.r,
                                      offset: Offset(0.w, 2.h),
                                    ),
                                  ],
                                ),
                                child: Row(
                                  children: [
                                    Icon(
                                      Icons.search_rounded,
                                      color: VoxAppColors.muted,
                                      size: 20.r,
                                    ),
                                    SizedBox(width: 10.w),
                                    Flexible(
                                      child: Text(
                                        'Search Recordings',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          color: VoxAppColors.muted,
                                          fontSize: 15.sp,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                          SizedBox(width: 12.w),
                          InkWell(
                            onTap: () => Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) => const SearchScreen(),
                              ),
                            ),
                            borderRadius: BorderRadius.circular(12.r),
                            child: Container(
                              width: 48.w,
                              height: 48.h,
                              decoration: BoxDecoration(
                                color: VoxAppColors.primary,
                                borderRadius: BorderRadius.circular(12.r),
                              ),
                              child: Icon(
                                Icons.tune_rounded,
                                color: Colors.white,
                                size: 20.r,
                              ),
                            ),
                          ),
                        ],
                      ),
                      SizedBox(height: 20.h),
                      const _DashedDivider(),
                      SizedBox(height: 12.h),
                      // Logs List View
                      Expanded(
                        child: AnimatedOpacity(
                          duration: const Duration(milliseconds: 200),
                          opacity: isRecording ? 0.55 : 1.0,
                          child: logs.when(
                            data: (rows) {
                              if (rows.isEmpty) return const _EmptyState();
                              return ListView.separated(
                                padding: EdgeInsets.only(
                                  bottom: navBarHeight + 36.h,
                                  top: 4.h,
                                ),
                                itemCount: rows.length,
                                separatorBuilder: (_, _) =>
                                    SizedBox(height: 10.h),
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
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),

        // 2b. Contour border painted precisely over the clipped canvas edge
        // Positioned.fill(
        //   child: IgnorePointer(
        //     child: CustomPaint(
        //       painter: _WhiteCanvasBorderPainter(
        //         bottomNavBarHeight: navBarHeight,
        //         borderColor: VoxAppColors.outline,
        //       ),
        //     ),
        //   ),
        // ),

        // 3. Symmetrical Silver Corner Screws / Studs
        // Placed relative to the corners of the refined faceplate panel
        Positioned(left: 12.w, top: 12.h, child: const _SilverStud()),
        Positioned(right: 12.w, top: 12.h, child: const _SilverStud()),

        // 4. The Bottom Nav Bar controls sitting on the exposed dark deck
        Positioned(
          left: 0.w,
          right: 0.w,
          bottom: 0.h,
          height: navBarHeight,
          child: const RecordingOverlay(),
        ),
      ],
    );
  }
}

class _DashedDivider extends StatelessWidget {
  const _DashedDivider();

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final boxWidth = constraints.constrainWidth();
        const dashWidth = 4.0;
        const dashSpace = 4.0;
        final dashCount = (boxWidth / (dashWidth + dashSpace)).floor();
        return Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: List.generate(dashCount, (_) {
            return SizedBox(
              width: dashWidth,
              height: 1.h,
              child: const DecoratedBox(
                decoration: BoxDecoration(color: VoxAppColors.outline),
              ),
            );
          }),
        );
      },
    );
  }
}

class _SilverStud extends StatelessWidget {
  const _SilverStud();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 12.w,
      height: 12.h,
      decoration: BoxDecoration(
        color: const Color(0xFFE0E0E0),
        shape: BoxShape.circle,
        border: Border.all(color: const Color(0xFFB0B0B0), width: 1.w),
        boxShadow: [
          BoxShadow(
            color: const Color(0x1A000000),
            blurRadius: 1.r,
            offset: Offset(0.w, 1.h),
          ),
        ],
      ),
      child: Center(
        child: Container(
          width: 3.w,
          height: 3.h,
          decoration: const BoxDecoration(
            color: Color(0xFF888888),
            shape: BoxShape.circle,
          ),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: EdgeInsets.all(24.r),
        child: Text(
          'Your journal gets smarter as you record more.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 16.sp, fontFamily: 'monospace'),
        ),
      ),
    );
  }
}

/// White canvas scoop design values, based on the iPhone 17 Pro Max
/// ScreenUtil baseline. Keep these as plain design units; the getters below
/// convert them to responsive runtime pixels.
double _whiteCanvasCornerRadius = 40.0;
double _whiteCanvasScoopWidth = 135.0;
double _whiteCanvasScoopHeight = 58.0;

/// Controls the rounded outer shoulder where the bottom edge turns into the scoop.
/// Increase this value for a wider/softer scoop edge, decrease for a tighter edge.
double _whiteCanvasScoopOuterEdgeRadius = 40.0;

/// Controls the upper curvature of the scoop as it reaches the top center.
/// Increase this value for a rounder/flatter scoop top, decrease for a sharper top.
double _whiteCanvasScoopTopRadius = 10.0;

double get _responsiveWhiteCanvasCornerRadius => _whiteCanvasCornerRadius.r;
double get _responsiveWhiteCanvasScoopWidth => _whiteCanvasScoopWidth.w;
double get _responsiveWhiteCanvasScoopHeight => _whiteCanvasScoopHeight.h;
double get _responsiveWhiteCanvasScoopOuterEdgeRadius =>
    _whiteCanvasScoopOuterEdgeRadius.r;
double get _responsiveWhiteCanvasScoopTopRadius => _whiteCanvasScoopTopRadius.r;

/// Custom Clipper to shape the white dashboard panel with rounded corners and
/// a beautiful curved scoop in the bottom center to reveal the record button.
class _WhiteCanvasClipper extends CustomClipper<Path> {
  final double bottomNavBarHeight;
  _WhiteCanvasClipper({required this.bottomNavBarHeight});

  @override
  Path getClip(Size size) {
    final path = Path();
    final double cornerRadius = _responsiveWhiteCanvasCornerRadius;
    final double scoopWidth = _responsiveWhiteCanvasScoopWidth;
    final double scoopHeight = _responsiveWhiteCanvasScoopHeight;
    final double scoopOuterEdgeRadius =
        _responsiveWhiteCanvasScoopOuterEdgeRadius;
    final double scoopTopRadius = _responsiveWhiteCanvasScoopTopRadius;
    final double centerX = size.width / 2;
    final double bottomY = size.height - bottomNavBarHeight;

    // Start at top-left
    path.moveTo(0, cornerRadius);
    path.quadraticBezierTo(0, 0, cornerRadius, 0);
    path.lineTo(size.width - cornerRadius, 0);
    path.quadraticBezierTo(size.width, 0, size.width, cornerRadius);

    // Go down to bottom-right corner of white faceplate
    path.lineTo(size.width, bottomY - cornerRadius);
    path.quadraticBezierTo(
      size.width,
      bottomY,
      size.width - cornerRadius,
      bottomY,
    );

    // Bottom edge to start of scoop
    path.lineTo(centerX + scoopWidth / 2 + scoopOuterEdgeRadius, bottomY);

    // Smooth bezier arch going UP
    path.cubicTo(
      centerX + scoopWidth / 2 - scoopOuterEdgeRadius * 0.5,
      bottomY,
      centerX + scoopWidth / 2 - scoopTopRadius,
      bottomY - scoopHeight,
      centerX,
      bottomY - scoopHeight,
    );
    path.cubicTo(
      centerX - scoopWidth / 2 + scoopTopRadius,
      bottomY - scoopHeight,
      centerX - scoopWidth / 2 + scoopOuterEdgeRadius * 0.5,
      bottomY,
      centerX - scoopWidth / 2 - scoopOuterEdgeRadius,
      bottomY,
    );

    // Bottom edge to bottom-left corner
    path.lineTo(cornerRadius, bottomY);
    path.quadraticBezierTo(0, bottomY, 0, bottomY - cornerRadius);

    path.close();
    return path;
  }

  @override
  bool shouldReclip(covariant _WhiteCanvasClipper oldClipper) {
    return oldClipper.bottomNavBarHeight != bottomNavBarHeight;
  }
}

/// Custom Painter to draw a fine outline along the entire clipped boundary of
/// the white dashboard panel.
// ignore: unused_element
class _WhiteCanvasBorderPainter extends CustomPainter {
  final double bottomNavBarHeight;
  final Color borderColor;

  _WhiteCanvasBorderPainter({
    required this.bottomNavBarHeight,
    required this.borderColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = borderColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2.r;

    final path = Path();
    final double cornerRadius = _responsiveWhiteCanvasCornerRadius;
    final double scoopWidth = _responsiveWhiteCanvasScoopWidth;
    final double scoopHeight = _responsiveWhiteCanvasScoopHeight;
    final double scoopOuterEdgeRadius =
        _responsiveWhiteCanvasScoopOuterEdgeRadius;
    final double scoopTopRadius = _responsiveWhiteCanvasScoopTopRadius;
    final double centerX = size.width / 2;
    final double bottomY = size.height - bottomNavBarHeight;

    path.moveTo(0, cornerRadius);
    path.quadraticBezierTo(0, 0, cornerRadius, 0);
    path.lineTo(size.width - cornerRadius, 0);
    path.quadraticBezierTo(size.width, 0, size.width, cornerRadius);
    path.lineTo(size.width, bottomY - cornerRadius);
    path.quadraticBezierTo(
      size.width,
      bottomY,
      size.width - cornerRadius,
      bottomY,
    );
    path.lineTo(centerX + scoopWidth / 2 + scoopOuterEdgeRadius, bottomY);

    path.cubicTo(
      centerX + scoopWidth / 2 - scoopOuterEdgeRadius * 0.5,
      bottomY,
      centerX + scoopWidth / 2 - scoopTopRadius,
      bottomY - scoopHeight,
      centerX,
      bottomY - scoopHeight,
    );
    path.cubicTo(
      centerX - scoopWidth / 2 + scoopTopRadius,
      bottomY - scoopHeight,
      centerX - scoopWidth / 2 + scoopOuterEdgeRadius * 0.5,
      bottomY,
      centerX - scoopWidth / 2 - scoopOuterEdgeRadius,
      bottomY,
    );

    path.lineTo(cornerRadius, bottomY);
    path.quadraticBezierTo(0, bottomY, 0, bottomY - cornerRadius);
    path.close();

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _WhiteCanvasBorderPainter oldDelegate) {
    return oldDelegate.bottomNavBarHeight != bottomNavBarHeight ||
        oldDelegate.borderColor != borderColor;
  }
}
