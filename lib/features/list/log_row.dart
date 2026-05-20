import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app_theme.dart';
import '../../core/db/processing_state.dart';
import '../../core/db/providers.dart';
import '../../core/db/repositories/entity_mention_repository.dart';
import '../../core/db/repositories/voice_log_repository.dart';

/// One row in the home list. Shows date, duration, the log title, and a
/// processing-state badge. When refine completes and the title transitions
/// from a raw-transcript fallback to the Gemma-generated title, the title
/// plays a one-shot reveal animation (fade + slight slide-up + shimmer
/// sweep) so users see the moment a log becomes "named".
class LogRow extends ConsumerStatefulWidget {
  const LogRow({super.key, required this.log, required this.onTap});

  final VoiceLogView log;
  final VoidCallback onTap;

  @override
  ConsumerState<LogRow> createState() => _LogRowState();
}

class _LogRowState extends ConsumerState<LogRow> with SingleTickerProviderStateMixin {
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
    final mentions = ref.watch(voiceLogMentionsProvider(log.id)).valueOrNull ?? [];
    
    final hasTitle = _hasRealTitle(log);
    final titleText = hasTitle ? log.title! : '';
    
    final isTitlePending = !hasTitle && log.processingState == ProcessingState.recorded;

    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      elevation: 2,
      shadowColor: Colors.black.withValues(alpha: 0.04),
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: VoxAppColors.outline, width: 1),
      ),
      child: InkWell(
        onTap: widget.onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 14.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Top Section: Square Mic Block, Title, and Date
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Symmetrical Dark Mic Block
                  Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      color: VoxAppColors.primary, // dark charcoal
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(
                      Icons.mic_rounded,
                      color: Colors.white,
                      size: 20,
                    ),
                  ),
                  const SizedBox(width: 12),
                  // Expanded block for Title & Date
                  Expanded(
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
                                      fontFamily: 'monospace',
                                      color: titleText.isEmpty 
                                          ? theme.colorScheme.onSurfaceVariant 
                                          : theme.colorScheme.onSurface,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                        Text(
                          _formatDate(log.createdAt),
                          style: TextStyle(
                            fontSize: 12,
                            color: VoxAppColors.muted,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        if (log.rawTranscript.isNotEmpty) ...[
                          const SizedBox(height: 6),
                          Text(
                            log.rawTranscript,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13,
                              color: VoxAppColors.muted,
                              fontFamily: 'monospace',
                              height: 1.3,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
              if (mentions.isNotEmpty) ...[
                const SizedBox(height: 10),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: mentions.map((m) => _TagChip(mention: m)).toList(),
                ),
              ],
              const SizedBox(height: 12),
              // Dotted Separator line
              const _CardDashedDivider(),
              const SizedBox(height: 12),
              // Bottom Section: Preview Waveform and Play Button
              Row(
                children: [
                  Expanded(
                    child: _PreviewWaveform(logId: log.id, durationMs: log.durationMs),
                  ),
                  const SizedBox(width: 14),
                  // Classic Square Black Play Button
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: VoxAppColors.primary,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Icon(
                      Icons.play_arrow_rounded,
                      color: Colors.white,
                      size: 20,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _formatDate(DateTime date) {
    final months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final m = months[date.month - 1];
    final h = date.hour > 12 ? date.hour - 12 : (date.hour == 0 ? 12 : date.hour);
    final min = date.minute.toString().padLeft(2, '0');
    final ampm = date.hour >= 12 ? 'PM' : 'AM';
    return '$m ${date.day} at $h:$min$ampm';
  }
}

class _CardDashedDivider extends StatelessWidget {
  const _CardDashedDivider();

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final boxWidth = constraints.constrainWidth();
        const dashWidth = 3.0;
        const dashSpace = 3.0;
        final dashCount = (boxWidth / (dashWidth + dashSpace)).floor();
        return Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: List.generate(dashCount, (_) {
            return SizedBox(
              width: dashWidth,
              height: 1,
              child: DecoratedBox(
                decoration: BoxDecoration(color: VoxAppColors.outline),
              ),
            );
          }),
        );
      },
    );
  }
}

class _PreviewWaveform extends StatelessWidget {
  const _PreviewWaveform({required this.logId, required this.durationMs});
  final String logId;
  final int durationMs;

  @override
  Widget build(BuildContext context) {
    // Generate a beautiful, clean pseudo-waveform based on logId hash for consistent styling
    final random = Random(logId.hashCode);
    final barCount = 28;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: List.generate(barCount, (index) {
        // Create organic symmetric looking heights
        final distanceToCenter = (index - barCount / 2).abs() / (barCount / 2);
        final factor = 1.0 - distanceToCenter;
        final rawHeight = 3.0 + 15.0 * factor + random.nextDouble() * 6.0;
        final height = rawHeight.clamp(4.0, 24.0);

        return Container(
          width: 3.5,
          height: height,
          decoration: BoxDecoration(
            color: index % 3 == 0 ? const Color(0xFFDCDCDC) : const Color(0xFFEBEBEB),
            borderRadius: BorderRadius.circular(1.5),
          ),
        );
      }),
    );
  }
}

class _TagChip extends StatelessWidget {
  const _TagChip({required this.mention});
  final EntityMentionView mention;

  @override
  Widget build(BuildContext context) {
    final color = _colorForType(mention.type);
    final icon = _iconForType(mention.type);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.15), width: 0.8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 10,
            color: color,
          ),
          const SizedBox(width: 4),
          Text(
            mention.text,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.bold,
              color: color,
              fontFamily: 'monospace',
            ),
          ),
        ],
      ),
    );
  }

  IconData _iconForType(String type) {
    switch (type.toUpperCase()) {
      case 'PERSON':
        return Icons.person_rounded;
      case 'PLACE':
        return Icons.place_rounded;
      case 'PROJECT':
        return Icons.folder_rounded;
      default:
        return Icons.label_rounded;
    }
  }

  Color _colorForType(String type) {
    switch (type.toUpperCase()) {
      case 'PERSON':
        return const Color(0xFF2F80ED);
      case 'PLACE':
        return const Color(0xFF27AE60);
      case 'PROJECT':
        return VoxAppColors.accent; // Retro Red
      default:
        return VoxAppColors.muted;
    }
  }
}

class _TitleReveal extends StatelessWidget {
  const _TitleReveal({required this.animation, required this.text});

  final Animation<double> animation;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final base = theme.textTheme.titleMedium?.copyWith(
      fontWeight: FontWeight.bold,
      fontFamily: 'monospace',
    ) ?? const TextStyle();
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
    final primaryColor = VoxAppColors.accent;
    final accentColor = VoxAppColors.muted;

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final t = _controller.value;
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Transform.rotate(
              angle: t * 2 * pi,
              child: ShaderMask(
                shaderCallback: (bounds) => LinearGradient(
                  colors: [primaryColor, accentColor],
                ).createShader(bounds),
                child: const Icon(
                  Icons.auto_awesome_rounded,
                  size: 14,
                  color: Colors.white,
                ),
              ),
            ),
            const SizedBox(width: 6),
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
                    fontFamily: 'monospace',
                    letterSpacing: 0.1,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
            const SizedBox(width: 6),
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
          width: 2.5,
          height: height,
          margin: const EdgeInsets.symmetric(horizontal: 1.0),
          decoration: BoxDecoration(
            color: const Color(0xFFE13C30).withValues(alpha: index.isEven ? 0.8 : 0.4),
            borderRadius: BorderRadius.circular(1.0),
          ),
        );
      }),
    );
  }
}
