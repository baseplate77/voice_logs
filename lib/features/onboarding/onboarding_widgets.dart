import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'onboarding_screen_data.dart';
import 'onboarding_visuals.dart';

/// Reusable building block widgets for onboarding flow.

// ==========================================
// 1. PAGE INDICATOR (6 dots, active is a wider pill)
// ==========================================
class PageIndicator extends StatelessWidget {
  final int count;
  final int currentIndex;

  const PageIndicator({
    super.key,
    required this.count,
    required this.currentIndex,
  });

  @override
  Widget build(BuildContext context) {
    final activeColor = OnboardingColors.primary(context);
    final inactiveColor = OnboardingColors.border(context);

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(count, (index) {
        final isSelected = index == currentIndex;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 320),
          curve: Curves.easeInOutCubic,
          margin: EdgeInsets.symmetric(horizontal: 4.w),
          height: 8.h,
          width: isSelected ? 24.w : 8.w,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(4.r),
            color: isSelected ? activeColor : inactiveColor,
          ),
        );
      }),
    );
  }
}

// ==========================================
// 2. TACTILE PRIMARY BUTTON (With scale feedback)
// ==========================================
class PrimaryButton extends StatefulWidget {
  final String label;
  final VoidCallback onPressed;

  const PrimaryButton({
    super.key,
    required this.label,
    required this.onPressed,
  });

  @override
  State<PrimaryButton> createState() => _PrimaryButtonState();
}

class _PrimaryButtonState extends State<PrimaryButton>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scaleAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 100),
      lowerBound: 0.95,
    );
    _scaleAnimation = _controller;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final primary = OnboardingColors.primary(context);
    final textBrightness = Theme.of(context).brightness;

    return GestureDetector(
      onTapDown: (_) => _controller.reverse(),
      onTapUp: (_) {
        _controller.forward();
        widget.onPressed();
      },
      onTapCancel: () => _controller.forward(),
      child: AnimatedBuilder(
        animation: _scaleAnimation,
        builder: (context, child) {
          return Transform.scale(scale: _scaleAnimation.value, child: child);
        },
        child: Container(
          width: double.infinity,
          height: 52.h,
          decoration: BoxDecoration(
            color: primary,
            borderRadius: BorderRadius.circular(14.r),
            boxShadow: [
              BoxShadow(
                color: primary.withValues(alpha: 0.1),
                blurRadius: 8.r,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          alignment: Alignment.center,
          child: Text(
            widget.label,
            style: TextStyle(
              fontSize: 14.sp,
              fontWeight: FontWeight.bold,
              fontFamily: 'JetBrainsMono',
              color: textBrightness == Brightness.dark
                  ? const Color(0xFF101413)
                  : Colors.white,
            ),
          ),
        ),
      ),
    );
  }
}

// ==========================================
// 3. ONBOARDING SCREEN CARD WRAPPER
// ==========================================
class OnboardingScreen extends StatelessWidget {
  final OnboardingScreenData data;
  final Widget visualWidget;

  const OnboardingScreen({
    super.key,
    required this.data,
    required this.visualWidget,
  });

  @override
  Widget build(BuildContext context) {
    final textPrimary = OnboardingColors.textPrimary(context);
    final textSecondary = OnboardingColors.textSecondary(context);

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 24.w),
      child: Column(
        children: [
          // Visual Area
          Expanded(flex: 9, child: Center(child: visualWidget)),
          // Copy Area
          Expanded(
            flex: 7,
            child: TweenAnimationBuilder<double>(
              duration: const Duration(milliseconds: 700),
              curve: Curves.easeOutQuart,
              tween: Tween<double>(begin: 0.0, end: 1.0),
              builder: (context, value, child) {
                return Opacity(
                  opacity: value,
                  child: Transform.translate(
                    offset: Offset(0, 24 * (1.0 - value)),
                    child: child,
                  ),
                );
              },
              child: Column(
                children: [
                  Text(
                    data.title,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 22.sp,
                      fontWeight: FontWeight.bold,
                      height: 1.25,
                      fontFamily: 'NDOT',
                      color: textPrimary,
                    ),
                  ),
                  SizedBox(height: 12.h),
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: 10.w),
                    child: Text(
                      data.subtitle,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 13.sp,
                        height: 1.5,
                        fontFamily: 'JetBrainsMono',
                        color: textSecondary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
