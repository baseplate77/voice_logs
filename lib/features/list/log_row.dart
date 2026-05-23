import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:iconsax/iconsax.dart';

import '../../app_theme.dart';
import '../../core/db/processing_state.dart';
import '../../core/db/providers.dart';
import '../../core/db/repositories/entity_mention_repository.dart';
import '../../core/db/repositories/voice_log_repository.dart';

/// One row in the home list. The card surfaces, in order of glanceability:
///   • the generated title (or a "Crafting title…" loader while refine runs)
///   • a one-line content preview drawn from `cleanedText`
///   • a footer with relative time · audio duration · pending-action badge
///     · typed entity chips (Person / Place / Project), capped at three
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
    _maybeRevealTitle(oldWidget.log, widget.log);
  }

  void _maybeRevealTitle(VoiceLogView before, VoiceLogView after) {
    final hadBefore = _hasRealTitle(before);
    final hasNow = _hasRealTitle(after);
    if (!hadBefore && hasNow) {
      if (_controller.value >= 1.0) {
        _controller.value = 0;
      }
      _controller
        ..reset()
        ..forward();
    } else if (hadBefore && !hasNow) {
      _controller.value = 0;
    } else if (hasNow && _controller.value < 1.0) {
      _controller.forward();
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
        ref.watch(voiceLogMentionsProvider(log.id)).valueOrNull ?? const [];
    final pendingActions = ref.watch(pendingActionCountsByLogProvider)[log.id];

    final hasTitle = _hasRealTitle(log);
    final titleText = hasTitle ? log.title!.trim() : log.displayTitle.trim();

    final isTranscribing = log.processingState == ProcessingState.transcribing;
    final isTitlePending =
        !hasTitle && log.processingState == ProcessingState.recorded;
    // Refine has produced a title but embed/canonicalize/action jobs may
    // still be running in the background. Surfacing this here closes the
    // "card looks done but isn't" gap.
    final isIndexing =
        hasTitle &&
        log.processingState != ProcessingState.embedded &&
        log.processingState != ProcessingState.failed;

    if (hasTitle && _controller.value < 1.0 && !_controller.isAnimating) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_hasRealTitle(widget.log)) return;
        if (_controller.value < 1.0) _controller.forward();
      });
    }

    final preview = _previewLine(log);

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
          padding: EdgeInsets.fromLTRB(14.w, 12.h, 14.w, 12.h),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (isTranscribing)
                const _TitleLoader(label: 'Transcribing audio...')
              else if (isTitlePending)
                const _TitleLoader(label: 'Crafting title...')
              else if (hasTitle && _controller.value < 1.0)
                _TitleReveal(animation: _controller, text: titleText)
              else
                Text(
                  titleText.isEmpty ? 'New voice log' : titleText,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.1,
                    color: titleText.isEmpty
                        ? theme.colorScheme.onSurfaceVariant
                        : theme.colorScheme.onSurface,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              if (preview != null) ...[
                SizedBox(height: 3.h),
                Text(
                  preview,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontSize: 13.sp,
                    color: VoxAppColors.muted,
                    height: 1.25,
                  ),
                ),
              ],
              SizedBox(height: 8.h),
              _RowFooter(
                createdAt: log.createdAt,
                durationMs: log.durationMs,
                pendingActions: pendingActions ?? 0,
                mentions: mentions,
                showIndexing: isIndexing,
              ),
            ],
          ),
        ),
      ),
    );
  }

  String? _previewLine(VoiceLogView log) {
    final source = (log.cleanedText ?? '').trim();
    if (source.isEmpty) return null;
    final firstNewline = source.indexOf('\n');
    final candidate = firstNewline >= 0
        ? source.substring(0, firstNewline).trim()
        : source;
    // Skip the first line if it's identical to the generated title — no
    // point repeating the same words on two adjacent rows.
    final titleTrimmed = log.title?.trim();
    if (titleTrimmed != null &&
        candidate.toLowerCase() == titleTrimmed.toLowerCase()) {
      if (firstNewline < 0) return null;
      final rest = source.substring(firstNewline + 1).trim();
      return rest.isEmpty ? null : rest.split('\n').first.trim();
    }
    return candidate.isEmpty ? null : candidate;
  }
}

class _RowFooter extends StatelessWidget {
  const _RowFooter({
    required this.createdAt,
    required this.durationMs,
    required this.pendingActions,
    required this.mentions,
    required this.showIndexing,
  });

  final DateTime createdAt;
  final int durationMs;
  final int pendingActions;
  final List<EntityMentionView> mentions;
  final bool showIndexing;

  @override
  Widget build(BuildContext context) {
    final (chips, overflow) = _typedMentionChips(mentions);
    final timeAndDuration = _formatTimeAndDuration();

    return Row(
      children: [
        Text(
          timeAndDuration,
          style: TextStyle(
            fontSize: 11.sp,
            color: VoxAppColors.muted,
            fontWeight: FontWeight.w500,
          ),
        ),
        if (showIndexing) ...[SizedBox(width: 8.w), const _IndexingPill()],
        if (pendingActions > 0) ...[
          SizedBox(width: 8.w),
          _ActionBadge(count: pendingActions),
        ],
        if (chips.isNotEmpty) ...[
          SizedBox(width: 8.w),
          Expanded(
            child: Wrap(
              spacing: 4.w,
              runSpacing: 4.h,
              children: [
                ...chips,
                if (overflow > 0) _OverflowChip(remaining: overflow),
              ],
            ),
          ),
        ] else
          const Spacer(),
      ],
    );
  }

  String _formatTimeAndDuration() {
    final time = _relativeTime(createdAt);
    if (durationMs <= 0) return time;
    return '$time · ${_formatDuration(durationMs)}';
  }

  /// Returns up to 3 typed mention chips plus the count of additional
  /// unique mentions that didn't fit.
  (List<Widget>, int) _typedMentionChips(List<EntityMentionView> mentions) {
    if (mentions.isEmpty) return (const [], 0);
    const allowedTypes = {'PERSON', 'PLACE', 'PROJECT'};
    final seenKeys = <String>{};
    final chips = <Widget>[];
    var overflow = 0;
    for (final mention in mentions) {
      final type = mention.type.toUpperCase();
      if (!allowedTypes.contains(type)) continue;
      final key = '$type:${mention.text.toLowerCase()}';
      if (!seenKeys.add(key)) continue;
      if (chips.length < 3) {
        chips.add(_MentionChip(type: type, text: mention.text));
      } else {
        overflow++;
      }
    }
    return (chips, overflow);
  }
}

class _MentionChip extends StatelessWidget {
  const _MentionChip({required this.type, required this.text});
  final String type;
  final String text;

  @override
  Widget build(BuildContext context) {
    final (icon, color) = switch (type) {
      'PERSON' => (Iconsax.user, const Color(0xFF7A6FCE)),
      'PLACE' => (Iconsax.location, const Color(0xFFCE7A4F)),
      'PROJECT' => (Iconsax.flash_1, const Color(0xFF4F8FCE)),
      _ => (Iconsax.tag, VoxAppColors.muted),
    };
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 6.w, vertical: 2.h),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(6.r),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 10.r, color: color),
          SizedBox(width: 3.w),
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: 110.w),
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 10.5.sp,
                fontWeight: FontWeight.w600,
                color: color,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _OverflowChip extends StatelessWidget {
  const _OverflowChip({required this.remaining});
  final int remaining;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 6.w, vertical: 2.h),
      decoration: BoxDecoration(
        color: VoxAppColors.surfaceHigh,
        borderRadius: BorderRadius.circular(6.r),
      ),
      child: Text(
        '+$remaining',
        style: TextStyle(
          fontSize: 10.5.sp,
          fontWeight: FontWeight.w600,
          color: VoxAppColors.muted,
        ),
      ),
    );
  }
}

class _ActionBadge extends StatelessWidget {
  const _ActionBadge({required this.count});
  final int count;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 6.w, vertical: 2.h),
      decoration: BoxDecoration(
        color: VoxAppColors.accent.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(6.r),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Iconsax.tick_square, size: 11.r, color: VoxAppColors.accent),
          SizedBox(width: 3.w),
          Text(
            '$count',
            style: TextStyle(
              fontSize: 10.5.sp,
              fontWeight: FontWeight.w700,
              color: VoxAppColors.accent,
              fontFamily: AppFonts.mono,
            ),
          ),
        ],
      ),
    );
  }
}

/// Subtle "still processing" pill shown on the card while embed,
/// canonicalize, action extraction, or memory jobs are still running for
/// a log that already has a title and cleaned text. Disappears once the
/// log reaches [ProcessingState.embedded] so a finished card is visually
/// distinct from one that's still being indexed.
class _IndexingPill extends StatefulWidget {
  const _IndexingPill();

  @override
  State<_IndexingPill> createState() => _IndexingPillState();
}

class _IndexingPillState extends State<_IndexingPill>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final alpha = 0.55 + 0.45 * _controller.value;
        return Container(
          padding: EdgeInsets.symmetric(horizontal: 6.w, vertical: 2.h),
          decoration: BoxDecoration(
            color: VoxAppColors.muted.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(6.r),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 6.r,
                height: 6.r,
                decoration: BoxDecoration(
                  color: VoxAppColors.muted.withValues(alpha: alpha),
                  shape: BoxShape.circle,
                ),
              ),
              SizedBox(width: 4.w),
              Text(
                'Indexing',
                style: TextStyle(
                  fontSize: 10.5.sp,
                  fontWeight: FontWeight.w600,
                  color: VoxAppColors.muted,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

String _relativeTime(DateTime date) {
  final now = DateTime.now();
  final diff = now.difference(date);

  if (diff.inMinutes < 1) return 'Just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
  if (diff.inHours < 24) return '${diff.inHours}h ago';
  if (diff.inDays == 1) return 'Yesterday';
  if (diff.inDays < 7) return '${diff.inDays}d ago';

  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  return '${months[date.month - 1]} ${date.day}';
}

String _formatDuration(int ms) {
  final totalSec = ms ~/ 1000;
  final min = totalSec ~/ 60;
  final sec = totalSec % 60;
  return '$min:${sec.toString().padLeft(2, '0')}';
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
          fontWeight: FontWeight.w700,
          letterSpacing: -0.1,
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

/// In-place loader rendered where the title will eventually appear.
/// Used for both the "Transcribing audio…" (state=transcribing) and
/// "Crafting title…" (state=recorded, no title yet) phases — the label
/// is the only thing that changes between them.
class _TitleLoader extends StatefulWidget {
  const _TitleLoader({required this.label});
  final String label;

  @override
  State<_TitleLoader> createState() => _TitleLoaderState();
}

class _TitleLoaderState extends State<_TitleLoader>
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
                  widget.label,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
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
