import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../app_theme.dart';
import '../../core/db/processing_state.dart';
import '../../core/db/providers.dart';
import '../../core/db/repositories/voice_log_repository.dart';

/// One row in the home list. Shows title + relative time + inline entity names.
/// When refine completes and the title transitions from a raw-transcript
/// fallback to the generated title, a one-shot reveal animation plays.
class LogRow extends ConsumerStatefulWidget {
  const LogRow({super.key, required this.log, required this.onTap});

  final VoiceLogView log;
  final VoidCallback onTap;

  @override
  ConsumerState<LogRow> createState() => _LogRowState();
}

class _LogRowState extends ConsumerState<LogRow>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  bool _hadTitleAtMount = false;

  @override
  void initState() {
    super.initState();
    _hadTitleAtMount = _hasRealTitle(widget.log);
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
      value: _hadTitleAtMount ? 1.0 : 0.0,
    );
  }

  @override
  void didUpdateWidget(covariant LogRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    final hadBefore = _hasRealTitle(oldWidget.log);
    final hasNow = _hasRealTitle(widget.log);
    if (!hadBefore && hasNow && !_hadTitleAtMount) {
      _controller
        ..reset()
        ..forward();
    } else if (hadBefore && !hasNow) {
      _controller.value = 0;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool _hasRealTitle(VoiceLogView log) {
    final t = log.title?.trim();
    return t != null && t.isNotEmpty;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final log = widget.log;
    final mentions =
        ref.watch(voiceLogMentionsProvider(log.id)).valueOrNull ?? [];

    final hasTitle = _hasRealTitle(log);
    final titleText = hasTitle ? log.title! : '';

    final isTitlePending =
        !hasTitle && log.processingState == ProcessingState.recorded;

    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      elevation: 2,
      shadowColor: Colors.black.withValues(alpha: 0.04),
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16.r),
        side: BorderSide(color: VoxAppColors.outline, width: 1.w),
      ),
      child: InkWell(
        onTap: widget.onTap,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 16.0.w, vertical: 14.0.h),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              isTitlePending
                  ? const _GenerativeTitleLoader()
                  : hasTitle && _controller.value < 1.0
                  ? _TitleReveal(animation: _controller, text: titleText)
                  : Text(
                      titleText.isEmpty ? 'New Voice Log' : titleText,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w900,
                        fontFamily: 'JetBrainsMono',
                        color: titleText.isEmpty
                            ? theme.colorScheme.onSurfaceVariant
                            : theme.colorScheme.onSurface,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
              SizedBox(height: 4.h),
              Row(
                children: [
                  Text(
                    _relativeTime(log.createdAt),
                    style: TextStyle(
                      fontSize: 12.sp,
                      color: VoxAppColors.muted,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  if (mentions.isNotEmpty) ...[
                    Padding(
                      padding: EdgeInsets.symmetric(horizontal: 6.w),
                      child: Text(
                        '·',
                        style: TextStyle(
                          fontSize: 12.sp,
                          color: VoxAppColors.muted,
                        ),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        mentions.map((m) => m.text).join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12.sp,
                          color: VoxAppColors.muted,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _relativeTime(DateTime date) {
    final now = DateTime.now();
    final diff = now.difference(date);

    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays == 1) return 'Yesterday';
    if (diff.inDays < 7) return '${diff.inDays}d ago';

    final months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    return '${months[date.month - 1]} ${date.day}';
  }
}

class _TitleReveal extends StatelessWidget {
  const _TitleReveal({required this.animation, required this.text});

  final Animation<double> animation;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final base =
        theme.textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.bold,
          fontFamily: 'JetBrainsMono',
        ) ??
        const TextStyle();
    return AnimatedBuilder(
      animation: animation,
      builder: (context, _) {
        final t = animation.value;
        final eased = Curves.easeOutCubic.transform(t);
        final opacity = (eased * 1.4).clamp(0.0, 1.0);
        final dy = (1 - eased) * 4;
        final sweep = (t * 1.4) - 0.2;
        return Transform.translate(
          offset: Offset(0, dy),
          child: Opacity(
            opacity: opacity,
            child: ShaderMask(
              blendMode: BlendMode.srcATop,
              shaderCallback: (rect) {
                final highlight = theme.colorScheme.primary.withValues(
                  alpha: (1 - t) * 0.45,
                );
                const transparent = Colors.transparent;
                return LinearGradient(
                  colors: [transparent, highlight, transparent],
                  stops: const [0.0, 0.5, 1.0],
                  begin: Alignment(sweep - 0.4, 0),
                  end: Alignment(sweep + 0.4, 0),
                ).createShader(rect);
              },
              child: Text(
                text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: base,
              ),
            ),
          ),
        );
      },
    );
  }
}

class _GenerativeTitleLoader extends StatefulWidget {
  const _GenerativeTitleLoader();

  @override
  State<_GenerativeTitleLoader> createState() => _GenerativeTitleLoaderState();
}

class _GenerativeTitleLoaderState extends State<_GenerativeTitleLoader>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const primaryColor = VoxAppColors.accent;
    const accentColor = VoxAppColors.muted;

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final t = _controller.value;
        return Row(
          children: [
            Transform.rotate(
              angle: t * 2 * pi,
              child: ShaderMask(
                shaderCallback: (bounds) => const LinearGradient(
                  colors: [primaryColor, accentColor],
                ).createShader(bounds),
                child: Icon(
                  Icons.auto_awesome_rounded,
                  size: 14.r,
                  color: Colors.white,
                ),
              ),
            ),
            SizedBox(width: 6.w),
            Expanded(
              child: ShaderMask(
                blendMode: BlendMode.srcATop,
                shaderCallback: (rect) {
                  final sweep = (t * 1.5) - 0.25;
                  return LinearGradient(
                    colors: [
                      theme.colorScheme.onSurface.withValues(alpha: 0.4),
                      primaryColor,
                      accentColor,
                      theme.colorScheme.onSurface.withValues(alpha: 0.4),
                    ],
                    stops: const [0.0, 0.4, 0.6, 1.0],
                    begin: Alignment(sweep - 0.5, 0),
                    end: Alignment(sweep + 0.5, 0),
                  ).createShader(rect);
                },
                child: Text(
                  'Crafting title...',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    fontFamily: 'JetBrainsMono',
                    letterSpacing: 0.1,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
            SizedBox(width: 6.w),
            _MicroWaveform(controller: _controller),
          ],
        );
      },
    );
  }
}

class _MicroWaveform extends StatelessWidget {
  const _MicroWaveform({required this.controller});
  final AnimationController controller;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(5, (index) {
        final phase = index * (pi / 4);
        final progress = controller.value * 2 * pi;
        final scale = 0.3 + 0.7 * (0.5 + 0.5 * sin(progress + phase));
        final height = 4.0 + 12.0 * scale;

        return Container(
          width: 2.5.w,
          height: height,
          margin: EdgeInsets.symmetric(horizontal: 1.0.w),
          decoration: BoxDecoration(
            color: const Color(
              0xFFE13C30,
            ).withValues(alpha: index.isEven ? 0.8 : 0.4),
            borderRadius: BorderRadius.circular(1.0.r),
          ),
        );
      }),
    );
  }
}
