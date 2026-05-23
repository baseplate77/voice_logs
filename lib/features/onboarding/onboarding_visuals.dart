import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:iconsax/iconsax.dart';

/// Central onboarding color tokens for light and dark themes.
class OnboardingColors {
  OnboardingColors._();

  // Light theme tokens
  static const Color lightBg = Color(0xFFFAFAF7);
  static const Color lightCard = Color(0xFFFFFFFF);
  static const Color lightPrimary = Color(0xFF0F4C5C);
  static const Color lightPrimaryDark = Color(0xFF0B3945);
  static const Color lightAccent = Color(0xFFD99A6C);
  static const Color lightTextPrimary = Color(0xFF1F2933);
  static const Color lightTextSecondary = Color(0xFF6B7280);
  static const Color lightBorder = Color(0xFFE7E5E1);
  static const Color privacyGreen = Color(0xFF4D7C59);

  // Dark theme tokens
  static const Color darkBg = Color(0xFF101413);
  static const Color darkCard = Color(0xFF171C1A);
  static const Color darkPrimary = Color(0xFF7BC6B6);
  static const Color darkAccent = Color(0xFFD99A6C);
  static const Color darkTextPrimary = Color(0xFFF4F1EA);
  static const Color darkTextSecondary = Color(0xFFA8AAA5);
  static const Color darkBorder = Color(0xFF2A302D);

  static Color background(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? darkBg : lightBg;

  static Color card(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? darkCard : lightCard;

  static Color primary(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
      ? darkPrimary
      : lightPrimary;

  static Color accent(BuildContext context) => darkAccent;

  static Color textPrimary(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
      ? darkTextPrimary
      : lightTextPrimary;

  static Color textSecondary(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
      ? darkTextSecondary
      : lightTextSecondary;

  static Color border(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
      ? darkBorder
      : lightBorder;
}

// ==========================================
// 1. VOICE ORB VISUAL (Screen 1)
// ==========================================
class VoiceOrbVisual extends StatefulWidget {
  const VoiceOrbVisual({super.key});

  @override
  State<VoiceOrbVisual> createState() => _VoiceOrbVisualState();
}

class _VoiceOrbVisualState extends State<VoiceOrbVisual>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3000),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final primaryColor = OnboardingColors.primary(context);
    final accentColor = OnboardingColors.accent(context);

    return SizedBox(
      height: 240.h,
      width: double.infinity,
      child: Center(
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, child) {
            return Stack(
              alignment: Alignment.center,
              children: [
                // Waveform Ring 3 (Outer)
                _buildExpandingRing(
                  progress: (_controller.value + 0.6) % 1.0,
                  color: accentColor.withValues(alpha: 0.12),
                ),
                // Waveform Ring 2 (Middle)
                _buildExpandingRing(
                  progress: (_controller.value + 0.3) % 1.0,
                  color: primaryColor.withValues(alpha: 0.15),
                ),
                // Waveform Ring 1 (Inner)
                _buildExpandingRing(
                  progress: _controller.value % 1.0,
                  color: primaryColor.withValues(alpha: 0.2),
                ),
                // Core Pulsing Orb
                Transform.scale(
                  scale:
                      1.0 +
                      (0.05 * (1.0 - (2.0 * (_controller.value - 0.5).abs()))),
                  child: Container(
                    width: 100.r,
                    height: 100.r,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: primaryColor,
                      boxShadow: [
                        BoxShadow(
                          color: primaryColor.withValues(alpha: 0.25),
                          blurRadius: 20.r,
                          spreadRadius: 4.r,
                        ),
                      ],
                    ),
                    child: Icon(
                      Iconsax.microphone_2,
                      size: 40.r,
                      color: Theme.of(context).brightness == Brightness.dark
                          ? const Color(0xFF101413)
                          : Colors.white,
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildExpandingRing({required double progress, required Color color}) {
    final double scale = 1.0 + (progress * 1.3);
    final double opacity = (1.0 - progress).clamp(0.0, 1.0);

    return Opacity(
      opacity: opacity,
      child: Transform.scale(
        scale: scale,
        child: Container(
          width: 105.r,
          height: 105.r,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: color, width: 1.5.w),
          ),
        ),
      ),
    );
  }
}

// ==========================================
// 2. PRIVACY DEVICE VISUAL (Screen 2)
// ==========================================
class PrivacyDeviceVisual extends StatefulWidget {
  const PrivacyDeviceVisual({super.key});

  @override
  State<PrivacyDeviceVisual> createState() => _PrivacyDeviceVisualState();
}

class _PrivacyDeviceVisualState extends State<PrivacyDeviceVisual>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _phoneScale;
  late Animation<double> _lockOpacity;
  final List<Animation<double>> _chipOpacities = [];

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2200),
    );

    _phoneScale = CurvedAnimation(
      parent: _controller,
      curve: const Interval(0.0, 0.4, curve: Curves.easeOutQuart),
    );

    _lockOpacity = CurvedAnimation(
      parent: _controller,
      curve: const Interval(0.3, 0.6, curve: Curves.easeInOut),
    );

    // Staggered fade in for the 4 chips
    for (int i = 0; i < 4; i++) {
      final start = 0.4 + (i * 0.12);
      final end = (start + 0.3).clamp(0.0, 1.0);
      _chipOpacities.add(
        CurvedAnimation(
          parent: _controller,
          curve: Interval(start, end, curve: Curves.easeOut),
        ),
      );
    }

    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final borderColor = OnboardingColors.border(context);
    final textPrimaryColor = OnboardingColors.textPrimary(context);
    final primaryColor = OnboardingColors.primary(context);
    final cardColor = OnboardingColors.card(context);

    return SizedBox(
      height: 240.h,
      width: double.infinity,
      child: Center(
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, child) {
            return Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // The Phone Frame
                ScaleTransition(
                  scale: _phoneScale,
                  child: Container(
                    width: 72.w,
                    height: 110.h,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16.r),
                      border: Border.all(color: borderColor, width: 2.2.w),
                      color: cardColor,
                      boxShadow: [
                        BoxShadow(
                          color: textPrimaryColor.withValues(alpha: 0.03),
                          blurRadius: 10.r,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        // Speaker notch
                        Positioned(
                          top: 6.h,
                          child: Container(
                            width: 20.w,
                            height: 3.h,
                            decoration: BoxDecoration(
                              color: borderColor,
                              borderRadius: BorderRadius.circular(2.r),
                            ),
                          ),
                        ),
                        // Lock Icon
                        FadeTransition(
                          opacity: _lockOpacity,
                          child: Container(
                            padding: EdgeInsets.all(8.r),
                            decoration: BoxDecoration(
                              color: OnboardingColors.privacyGreen.withValues(
                                alpha: 0.1,
                              ),
                              shape: BoxShape.circle,
                            ),
                            child: Icon(
                              Iconsax.lock,
                              color: OnboardingColors.privacyGreen,
                              size: 26.r,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                SizedBox(height: 24.h),
                // Chips Flow
                Wrap(
                  spacing: 8.w,
                  runSpacing: 8.h,
                  alignment: WrapAlignment.center,
                  children: [
                    _buildLocalChip(
                      'Audio',
                      _chipOpacities[0],
                      primaryColor,
                      cardColor,
                      borderColor,
                    ),
                    _buildLocalChip(
                      'Transcripts',
                      _chipOpacities[1],
                      primaryColor,
                      cardColor,
                      borderColor,
                    ),
                    _buildLocalChip(
                      'Search',
                      _chipOpacities[2],
                      primaryColor,
                      cardColor,
                      borderColor,
                    ),
                    _buildLocalChip(
                      'AI Chats',
                      _chipOpacities[3],
                      primaryColor,
                      cardColor,
                      borderColor,
                    ),
                  ],
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildLocalChip(
    String label,
    Animation<double> opacityAnim,
    Color primaryColor,
    Color cardColor,
    Color borderColor,
  ) {
    return FadeTransition(
      opacity: opacityAnim,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 0.2),
          end: Offset.zero,
        ).animate(opacityAnim),
        child: Container(
          padding: EdgeInsets.symmetric(horizontal: 10.w, vertical: 6.h),
          decoration: BoxDecoration(
            color: cardColor,
            borderRadius: BorderRadius.circular(10.r),
            border: Border.all(color: borderColor, width: 1.w),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.02),
                blurRadius: 4.r,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 6.r,
                height: 6.r,
                decoration: const BoxDecoration(
                  color: OnboardingColors.privacyGreen,
                  shape: BoxShape.circle,
                ),
              ),
              SizedBox(width: 6.w),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12.sp,
                  fontWeight: FontWeight.w600,
                  fontFamily: 'JetBrainsMono',
                  color: primaryColor,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ==========================================
// 3. AI PIPELINE VISUAL (Screen 3)
// ==========================================
class AIPipelineVisual extends StatefulWidget {
  const AIPipelineVisual({super.key});

  @override
  State<AIPipelineVisual> createState() => _AIPipelineVisualState();
}

class _AIPipelineVisualState extends State<AIPipelineVisual>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  final List<Animation<double>> _cardOpacities = [];
  final List<Animation<double>> _arrowOpacities = [];

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2500),
    );

    // Stagger 4 cards
    for (int i = 0; i < 4; i++) {
      final start = i * 0.2;
      final end = (start + 0.3).clamp(0.0, 1.0);
      _cardOpacities.add(
        CurvedAnimation(
          parent: _controller,
          curve: Interval(start, end, curve: Curves.easeOutQuart),
        ),
      );
    }

    // Stagger 3 arrow connections
    for (int i = 0; i < 3; i++) {
      final start = 0.15 + (i * 0.2);
      final end = (start + 0.2).clamp(0.0, 1.0);
      _arrowOpacities.add(
        CurvedAnimation(
          parent: _controller,
          curve: Interval(start, end, curve: Curves.easeInOut),
        ),
      );
    }

    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cardColor = OnboardingColors.card(context);
    final borderColor = OnboardingColors.border(context);
    final textPrimary = OnboardingColors.textPrimary(context);
    final accentColor = OnboardingColors.accent(context);

    return SizedBox(
      height: 240.h,
      width: double.infinity,
      child: Center(
        child: SingleChildScrollView(
          physics: const NeverScrollableScrollPhysics(),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _buildPipelineRow(
                context: context,
                index: 0,
                icon: Iconsax.microphone_2,
                title: 'Voice',
                desc: 'Captures physical audio locally',
                cardColor: cardColor,
                borderColor: borderColor,
                textPrimary: textPrimary,
              ),
              _buildPipelineConnector(_arrowOpacities[0], textPrimary),
              _buildPipelineRow(
                context: context,
                index: 1,
                icon: Iconsax.document_text_1,
                title: 'Transcript',
                desc: 'Real-time text-to-speech',
                cardColor: cardColor,
                borderColor: borderColor,
                textPrimary: textPrimary,
              ),
              _buildPipelineConnector(_arrowOpacities[1], textPrimary),
              _buildPipelineRow(
                context: context,
                index: 2,
                icon: Iconsax.note_2,
                title: 'Summary',
                desc: 'Clean structured bullet synthesis',
                cardColor: cardColor,
                borderColor: borderColor,
                textPrimary: textPrimary,
              ),
              _buildPipelineConnector(_arrowOpacities[2], textPrimary),
              _buildPipelineRow(
                context: context,
                index: 3,
                icon: Iconsax.tag,
                title: 'Labels',
                desc: 'Offline context topic extraction',
                cardColor: cardColor,
                borderColor: accentColor.withValues(alpha: 0.5),
                textPrimary: textPrimary,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPipelineRow({
    required BuildContext context,
    required int index,
    required IconData icon,
    required String title,
    required String desc,
    required Color cardColor,
    required Color borderColor,
    required Color textPrimary,
  }) {
    final opacityAnim = _cardOpacities[index];
    return FadeTransition(
      opacity: opacityAnim,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 0.15),
          end: Offset.zero,
        ).animate(opacityAnim),
        child: Container(
          width: 250.w,
          padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 8.h),
          decoration: BoxDecoration(
            color: cardColor,
            borderRadius: BorderRadius.circular(12.r),
            border: Border.all(color: borderColor, width: 1.w),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.02),
                blurRadius: 4.r,
                offset: const Offset(0, 1.5),
              ),
            ],
          ),
          child: Row(
            children: [
              Container(
                padding: EdgeInsets.all(6.r),
                decoration: BoxDecoration(
                  color: OnboardingColors.primary(
                    context,
                  ).withValues(alpha: 0.08),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  icon,
                  size: 16.r,
                  color: OnboardingColors.primary(context),
                ),
              ),
              SizedBox(width: 10.w),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 12.sp,
                        fontWeight: FontWeight.w700,
                        fontFamily: 'JetBrainsMono',
                        color: textPrimary,
                      ),
                    ),
                    Text(
                      desc,
                      style: TextStyle(
                        fontSize: 9.sp,
                        color: OnboardingColors.textSecondary(context),
                        fontFamily: 'JetBrainsMono',
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPipelineConnector(Animation<double> animation, Color color) {
    return FadeTransition(
      opacity: animation,
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: 2.h),
        child: Icon(
          Iconsax.arrow_down_1,
          size: 14.r,
          color: color.withValues(alpha: 0.35),
        ),
      ),
    );
  }
}

// ==========================================
// 4. NATURAL SEARCH VISUAL (Screen 4)
// ==========================================
class NaturalSearchVisual extends StatefulWidget {
  const NaturalSearchVisual({super.key});

  @override
  State<NaturalSearchVisual> createState() => _NaturalSearchVisualState();
}

class _NaturalSearchVisualState extends State<NaturalSearchVisual>
    with TickerProviderStateMixin {
  late AnimationController _searchBarController;
  late AnimationController _resultsController;
  late Animation<double> _searchBarScale;
  late Animation<double> _card1Opacity;
  late Animation<double> _card2Opacity;

  String _typedText = '';
  final String _query = 'What did I say about my startup idea?';
  Timer? _typingTimer;

  @override
  void initState() {
    super.initState();
    _searchBarController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );

    _resultsController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    );

    _searchBarScale = CurvedAnimation(
      parent: _searchBarController,
      curve: Curves.easeOutBack,
    );

    _card1Opacity = CurvedAnimation(
      parent: _resultsController,
      curve: const Interval(0.0, 0.6, curve: Curves.easeOut),
    );

    _card2Opacity = CurvedAnimation(
      parent: _resultsController,
      curve: const Interval(0.4, 1.0, curve: Curves.easeOut),
    );

    _searchBarController.forward().then((_) {
      _startTyping();
    });
  }

  void _startTyping() {
    int index = 0;
    _typingTimer = Timer.periodic(const Duration(milliseconds: 35), (timer) {
      if (!mounted) return;
      if (index < _query.length) {
        setState(() {
          _typedText += _query[index];
        });
        index++;
      } else {
        timer.cancel();
        // Once typing finished, trigger search results slide-in after small delay
        Future.delayed(const Duration(milliseconds: 300), () {
          if (mounted) {
            _resultsController.forward();
          }
        });
      }
    });
  }

  @override
  void dispose() {
    _typingTimer?.cancel();
    _searchBarController.dispose();
    _resultsController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cardBg = OnboardingColors.card(context);
    final borderColor = OnboardingColors.border(context);
    final textPrimary = OnboardingColors.textPrimary(context);
    final textSecondary = OnboardingColors.textSecondary(context);

    return SizedBox(
      height: 240.h,
      width: double.infinity,
      child: Center(
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 24.w),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Search Input Bar
              ScaleTransition(
                scale: _searchBarScale,
                child: Container(
                  padding: EdgeInsets.symmetric(
                    horizontal: 12.w,
                    vertical: 10.h,
                  ),
                  decoration: BoxDecoration(
                    color: cardBg,
                    borderRadius: BorderRadius.circular(12.r),
                    border: Border.all(color: borderColor, width: 1.2.w),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.03),
                        blurRadius: 8.r,
                        offset: const Offset(0, 3),
                      ),
                    ],
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Iconsax.search_normal_1,
                        size: 16.r,
                        color: textSecondary,
                      ),
                      SizedBox(width: 8.w),
                      Expanded(
                        child: Text(
                          _typedText.isEmpty ? 'Search logs...' : _typedText,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12.sp,
                            fontFamily: 'JetBrainsMono',
                            fontWeight: _typedText.isEmpty
                                ? FontWeight.normal
                                : FontWeight.w500,
                            color: _typedText.isEmpty
                                ? textSecondary.withValues(alpha: 0.5)
                                : textPrimary,
                          ),
                        ),
                      ),
                      if (_typedText.length < _query.length &&
                          _typedText.isNotEmpty)
                        Container(
                          width: 2.w,
                          height: 14.h,
                          color: OnboardingColors.primary(context),
                        ),
                    ],
                  ),
                ),
              ),
              SizedBox(height: 14.h),
              // Results Cards
              _buildSearchResultCard(
                opacity: _card1Opacity,
                title: '💡 Offline-first AI Voice Logs Idea',
                snippet:
                    '“...I want all the models to run entirely on the device. Gemma for summaries, e5 for search index...”',
                time: '2 hours ago',
                cardBg: cardBg,
                borderColor: borderColor,
                textPrimary: textPrimary,
                textSecondary: textSecondary,
              ),
              SizedBox(height: 8.h),
              _buildSearchResultCard(
                opacity: _card2Opacity,
                title: '📌 Tech stack lock notes',
                snippet:
                    '“...drift on sqlite3 with sqlcipher for storage. sqlite-vec extension for hybrid semantic search...”',
                time: 'Yesterday',
                cardBg: cardBg,
                borderColor: borderColor,
                textPrimary: textPrimary,
                textSecondary: textSecondary,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSearchResultCard({
    required Animation<double> opacity,
    required String title,
    required String snippet,
    required String time,
    required Color cardBg,
    required Color borderColor,
    required Color textPrimary,
    required Color textSecondary,
  }) {
    return FadeTransition(
      opacity: opacity,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 0.25),
          end: Offset.zero,
        ).animate(opacity),
        child: Container(
          padding: EdgeInsets.all(10.r),
          decoration: BoxDecoration(
            color: cardBg,
            borderRadius: BorderRadius.circular(10.r),
            border: Border.all(color: borderColor, width: 1.w),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11.sp,
                        fontWeight: FontWeight.w700,
                        fontFamily: 'JetBrainsMono',
                        color: textPrimary,
                      ),
                    ),
                  ),
                  Text(
                    time,
                    style: TextStyle(
                      fontSize: 8.sp,
                      fontFamily: 'JetBrainsMono',
                      color: textSecondary.withValues(alpha: 0.7),
                    ),
                  ),
                ],
              ),
              SizedBox(height: 4.h),
              Text(
                snippet,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 10.sp,
                  fontStyle: FontStyle.italic,
                  fontFamily: 'JetBrainsMono',
                  color: textSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ==========================================
// 5. LOCAL CHAT VISUAL (Screen 5)
// ==========================================
class LocalChatVisual extends StatefulWidget {
  const LocalChatVisual({super.key});

  @override
  State<LocalChatVisual> createState() => _LocalChatVisualState();
}

class _LocalChatVisualState extends State<LocalChatVisual>
    with TickerProviderStateMixin {
  late AnimationController _userController;
  late AnimationController _aiController;
  late AnimationController _badgeController;

  late Animation<double> _userScale;
  late Animation<double> _aiScale;
  late Animation<double> _badgeOpacity;

  @override
  void initState() {
    super.initState();
    _userController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );
    _aiController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _badgeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );

    _userScale = CurvedAnimation(
      parent: _userController,
      curve: Curves.easeOutBack,
    );

    _aiScale = CurvedAnimation(
      parent: _aiController,
      curve: Curves.easeOutBack,
    );

    _badgeOpacity = CurvedAnimation(
      parent: _badgeController,
      curve: Curves.easeIn,
    );

    // Stagger chat bubbles
    _userController.forward().then((_) {
      Future.delayed(const Duration(milliseconds: 400), () {
        if (mounted) {
          _aiController.forward().then((_) {
            _badgeController.forward();
          });
        }
      });
    });
  }

  @override
  void dispose() {
    _userController.dispose();
    _aiController.dispose();
    _badgeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final primaryColor = OnboardingColors.primary(context);
    final cardBg = OnboardingColors.card(context);
    final borderColor = OnboardingColors.border(context);
    final textPrimary = OnboardingColors.textPrimary(context);

    return SizedBox(
      height: 240.h,
      width: double.infinity,
      child: Center(
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 20.w),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // User Chat Bubble (Top-Right aligned)
              ScaleTransition(
                scale: _userScale,
                alignment: Alignment.centerRight,
                child: Align(
                  alignment: Alignment.centerRight,
                  child: Container(
                    padding: EdgeInsets.all(12.r),
                    margin: EdgeInsets.only(left: 36.w),
                    decoration: BoxDecoration(
                      color: primaryColor,
                      borderRadius: BorderRadius.only(
                        topLeft: Radius.circular(16.r),
                        topRight: Radius.circular(16.r),
                        bottomLeft: Radius.circular(16.r),
                      ),
                    ),
                    child: Text(
                      'What tasks did I mention this week?',
                      style: TextStyle(
                        fontSize: 11.5.sp,
                        color: Theme.of(context).brightness == Brightness.dark
                            ? const Color(0xFF101413)
                            : Colors.white,
                        fontFamily: 'JetBrainsMono',
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ),
              SizedBox(height: 10.h),
              // AI Chat Bubble (Bottom-Left aligned)
              ScaleTransition(
                scale: _aiScale,
                alignment: Alignment.centerLeft,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Container(
                    padding: EdgeInsets.all(12.r),
                    margin: EdgeInsets.only(right: 30.w),
                    decoration: BoxDecoration(
                      color: cardBg,
                      border: Border.all(color: borderColor, width: 1.2.w),
                      borderRadius: BorderRadius.only(
                        topLeft: Radius.circular(16.r),
                        topRight: Radius.circular(16.r),
                        bottomRight: Radius.circular(16.r),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Container(
                              width: 8.r,
                              height: 8.r,
                              decoration: const BoxDecoration(
                                color: OnboardingColors.privacyGreen,
                                shape: BoxShape.circle,
                              ),
                            ),
                            SizedBox(width: 6.w),
                            Text(
                              'Local AI Companion',
                              style: TextStyle(
                                fontSize: 10.sp,
                                fontWeight: FontWeight.bold,
                                fontFamily: 'JetBrainsMono',
                                color: primaryColor,
                              ),
                            ),
                          ],
                        ),
                        SizedBox(height: 6.h),
                        Text(
                          'You noted 2 tasks:\n1. Send client agenda before lunch on Monday.\n2. Add VAD thresholds to testing pipeline.',
                          style: TextStyle(
                            fontSize: 11.sp,
                            height: 1.35,
                            fontFamily: 'JetBrainsMono',
                            color: textPrimary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              SizedBox(height: 12.h),
              // "Runs locally" badge
              FadeTransition(
                opacity: _badgeOpacity,
                child: Center(
                  child: Container(
                    padding: EdgeInsets.symmetric(
                      horizontal: 10.w,
                      vertical: 5.h,
                    ),
                    decoration: BoxDecoration(
                      color: OnboardingColors.privacyGreen.withValues(
                        alpha: 0.12,
                      ),
                      borderRadius: BorderRadius.circular(12.r),
                      border: Border.all(
                        color: OnboardingColors.privacyGreen.withValues(
                          alpha: 0.25,
                        ),
                        width: 1.w,
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Iconsax.cpu_charge,
                          size: 12.r,
                          color: OnboardingColors.privacyGreen,
                        ),
                        SizedBox(width: 4.w),
                        Text(
                          'Runs locally',
                          style: TextStyle(
                            fontSize: 9.5.sp,
                            fontWeight: FontWeight.bold,
                            fontFamily: 'JetBrainsMono',
                            color: OnboardingColors.privacyGreen,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ==========================================
// 6. RECORD BUTTON VISUAL (Screen 6)
// ==========================================
class RecordButtonVisual extends StatefulWidget {
  const RecordButtonVisual({super.key});

  @override
  State<RecordButtonVisual> createState() => _RecordButtonVisualState();
}

class _RecordButtonVisualState extends State<RecordButtonVisual>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final accentColor = OnboardingColors.accent(context);

    return SizedBox(
      height: 240.h,
      width: double.infinity,
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            AnimatedBuilder(
              animation: _controller,
              builder: (context, child) {
                final double pulseVal = _controller.value;
                return Stack(
                  alignment: Alignment.center,
                  children: [
                    // Outer pulsing rings
                    Container(
                      width: 90.r + (pulseVal * 32.r),
                      height: 90.r + (pulseVal * 32.r),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: accentColor.withValues(
                          alpha: 0.15 * (1.0 - pulseVal),
                        ),
                      ),
                    ),
                    Container(
                      width: 90.r + (((pulseVal + 0.5) % 1.0) * 20.r),
                      height: 90.r + (((pulseVal + 0.5) % 1.0) * 20.r),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: accentColor.withValues(
                          alpha: 0.2 * (1.0 - ((pulseVal + 0.5) % 1.0)),
                        ),
                      ),
                    ),
                    // Core circular record button
                    Container(
                      width: 82.r,
                      height: 82.r,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: accentColor,
                        boxShadow: [
                          BoxShadow(
                            color: accentColor.withValues(alpha: 0.3),
                            blurRadius: 15.r,
                            spreadRadius: 2.r,
                          ),
                        ],
                      ),
                      child: Icon(
                        Iconsax.microphone,
                        size: 34.r,
                        color: Colors.white,
                      ),
                    ),
                  ],
                );
              },
            ),
            SizedBox(height: 28.h),
            // Processed locally badge
            Container(
              padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 6.h),
              decoration: BoxDecoration(
                color: OnboardingColors.privacyGreen.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(12.r),
                border: Border.all(
                  color: OnboardingColors.privacyGreen.withValues(alpha: 0.25),
                  width: 1.w,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Iconsax.shield_tick,
                    size: 13.r,
                    color: OnboardingColors.privacyGreen,
                  ),
                  SizedBox(width: 5.w),
                  Text(
                    'Processed locally',
                    style: TextStyle(
                      fontSize: 10.sp,
                      fontWeight: FontWeight.bold,
                      fontFamily: 'JetBrainsMono',
                      color: OnboardingColors.privacyGreen,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
