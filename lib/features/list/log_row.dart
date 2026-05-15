import 'package:flutter/material.dart';

import '../../core/db/processing_state.dart';
import '../../core/db/repositories/voice_log_repository.dart';

/// One row in the home list. Shows date, duration, the log title, and a
/// processing-state badge. When refine completes and the title transitions
/// from a raw-transcript fallback to the Gemma-generated title, the title
/// plays a one-shot reveal animation (fade + slight slide-up + shimmer
/// sweep) so users see the moment a log becomes "named".
class LogRow extends StatefulWidget {
  const LogRow({super.key, required this.log, required this.onTap});

  final VoiceLogView log;
  final VoidCallback onTap;

  @override
  State<LogRow> createState() => _LogRowState();
}

class _LogRowState extends State<LogRow> with SingleTickerProviderStateMixin {
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
      // Refine retry blew the title away. Reset silently so the next arrival
      // animates again.
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
    final log = widget.log;
    final hasTitle = _hasRealTitle(log);
    final displayed = _firstLine(log.displayTitle);
    final text = displayed.isEmpty ? '(no transcript)' : displayed;

    // While refine is still running and no title has landed yet, the row
    // would otherwise show the raw transcript as a fallback. Replace that
    // with a shimmer skeleton so the user clearly sees the title is being
    // generated rather than thinking the lower-case ASR text *is* the title.
    final isTitlePending =
        !hasTitle && log.processingState == ProcessingState.recorded;

    final Widget titleWidget;
    if (isTitlePending) {
      titleWidget = const _TitleSkeleton();
    } else if (hasTitle && _controller.value < 1.0) {
      titleWidget = _TitleReveal(animation: _controller, text: text);
    } else {
      titleWidget = Text(text, maxLines: 2, overflow: TextOverflow.ellipsis);
    }

    return ListTile(
      onTap: widget.onTap,
      title: titleWidget,
      subtitle: Text(_metaLine(log)),
      trailing: _badge(log.processingState),
    );
  }

  String _firstLine(String text) {
    final idx = text.indexOf('\n');
    final line = idx >= 0 ? text.substring(0, idx) : text;
    return line.trim();
  }

  String _metaLine(VoiceLogView log) {
    final when = _shortDate(log.createdAt);
    final dur = (log.durationMs / 1000).toStringAsFixed(1);
    return '$when  ·  ${dur}s';
  }

  String _shortDate(DateTime when) {
    final now = DateTime.now();
    final same =
        when.year == now.year && when.month == now.month && when.day == now.day;
    final h = when.hour.toString().padLeft(2, '0');
    final m = when.minute.toString().padLeft(2, '0');
    if (same) return '$h:$m';
    return '${when.month}/${when.day}  $h:$m';
  }

  Widget? _badge(ProcessingState state) {
    switch (state) {
      case ProcessingState.recorded:
        return const _Shimmer(label: 'refining');
      case ProcessingState.refined:
        return const _Shimmer(label: 'embedding');
      case ProcessingState.embedded:
        return null;
      case ProcessingState.failed:
        return Icon(
          Icons.error_outline,
          color: Theme.of(context).colorScheme.error,
        );
    }
  }
}

/// One-shot reveal for the moment a freshly generated title replaces the
/// transcript-fallback text on a row. Three layered effects on the same
/// timeline:
///   - opacity 0 → 1 over the first 60% of the curve
///   - 6 px slide-up easing into place
///   - a tinted highlight sweep that traverses the text and fades out
class _TitleReveal extends StatelessWidget {
  const _TitleReveal({required this.animation, required this.text});

  final Animation<double> animation;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final base = theme.textTheme.bodyLarge ?? const TextStyle();
    return AnimatedBuilder(
      animation: animation,
      builder: (context, _) {
        final t = animation.value;
        final eased = Curves.easeOutCubic.transform(t);
        final opacity = (eased * 1.4).clamp(0.0, 1.0);
        final dy = (1 - eased) * 6;
        // Shimmer band travels from -0.2 to 1.2 over the full timeline so it
        // enters before opacity peaks and trails off after the slide settles.
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
                maxLines: 2,
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

/// Skeleton bar shown in place of the title while Gemma is still generating
/// it. Two stacked lines mirroring the two-line title layout so the row
/// height stays stable when the real title fades in.
class _TitleSkeleton extends StatefulWidget {
  const _TitleSkeleton();

  @override
  State<_TitleSkeleton> createState() => _TitleSkeletonState();
}

class _TitleSkeletonState extends State<_TitleSkeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final base = Theme.of(
      context,
    ).colorScheme.onSurface.withValues(alpha: 0.08);
    final highlight = Theme.of(
      context,
    ).colorScheme.onSurface.withValues(alpha: 0.18);
    return AnimatedBuilder(
      animation: _pulse,
      builder: (_, _) {
        final color = Color.lerp(base, highlight, _pulse.value)!;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _bar(color, width: double.infinity),
            const SizedBox(height: 6),
            _bar(color, width: 140),
          ],
        );
      },
    );
  }

  Widget _bar(Color color, {required double width}) {
    return Container(
      width: width,
      height: 12,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(4),
      ),
    );
  }
}

class _Shimmer extends StatelessWidget {
  const _Shimmer({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      style: TextStyle(
        fontSize: 11,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
  }
}
