import 'package:flutter/material.dart';

import 'ask_answer_view.dart';
import 'ask_chat_message.dart';
import 'ask_citation_parser.dart';
import 'ask_context_panel.dart';

/// Chat bubble for one Ask message.
class AskChatBubble extends StatefulWidget {
  const AskChatBubble({
    super.key,
    required this.message,
    required this.onOpenLog,
  });

  /// Message to render.
  final AskChatMessage message;

  /// Called when the user taps a voice-log citation chip or source tile.
  /// The caller resolves the snippet to an audio offset before navigating.
  final OpenLogCallback onOpenLog;

  @override
  State<AskChatBubble> createState() => _AskChatBubbleState();
}

class _AskChatBubbleState extends State<AskChatBubble> {
  bool _referencesExpanded = false;

  @override
  Widget build(BuildContext context) {
    final message = widget.message;
    final isUser = message.role == AskChatRole.user;
    final colorScheme = Theme.of(context).colorScheme;
    final background = isUser
        ? colorScheme.surfaceContainerHighest
        : Colors.transparent;
    final foreground = colorScheme.onSurface;
    final references = _referencesFor(message);

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * (isUser ? 0.78 : 0.94),
        ),
        child: Card(
          elevation: 0,
          color: background,
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(20),
              topRight: const Radius.circular(20),
              bottomLeft: Radius.circular(isUser ? 20 : 6),
              bottomRight: Radius.circular(isUser ? 6 : 20),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: DefaultTextStyle.merge(
              style: TextStyle(color: foreground),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (isUser)
                    SelectableText(message.text)
                  else
                    AskAnswerView(
                      text: message.text,
                      showInlineCitations: false,
                      onTapCitation: _onTapCitation,
                    ),
                  if (message.streaming) ...[
                    const SizedBox(height: 8),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox.square(
                          dimension: 12,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: foreground,
                          ),
                        ),
                        const SizedBox(width: 8),
                        const Text('Streaming locally'),
                      ],
                    ),
                  ],
                  if (!isUser && !message.streaming && references.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: _ReferenceSummary(
                        citations: references,
                        expanded: _referencesExpanded,
                        onToggle: () => setState(
                          () => _referencesExpanded = !_referencesExpanded,
                        ),
                        onTapCitation: _onTapCitation,
                      ),
                    ),
                  if (!isUser &&
                      !message.streaming &&
                      _referencesExpanded &&
                      (message.memoryHits.isNotEmpty ||
                          message.logHits.isNotEmpty)) ...[
                    const SizedBox(height: 10),
                    Divider(
                      height: 1,
                      thickness: 1,
                      color: colorScheme.outlineVariant.withValues(alpha: 0.5),
                    ),
                    const SizedBox(height: 10),
                    AskContextPanel(
                      message: message,
                      onOpenLog: widget.onOpenLog,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _onTapCitation(Citation citation) {
    if (citation.kind != CitationKind.log) {
      setState(() => _referencesExpanded = true);
      return;
    }
    final hits = widget.message.logHits;
    final idx = citation.hitOffset;
    if (idx < 0 || idx >= hits.length) return;
    widget.onOpenLog(hits[idx]);
  }
}

class _ReferenceSummary extends StatelessWidget {
  const _ReferenceSummary({
    required this.citations,
    required this.expanded,
    required this.onToggle,
    required this.onTapCitation,
  });

  final List<Citation> citations;
  final bool expanded;
  final VoidCallback onToggle;
  final ValueChanged<Citation> onTapCitation;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        OutlinedButton.icon(
          onPressed: onToggle,
          icon: Icon(
            expanded ? Icons.expand_less : Icons.expand_more,
            size: 16,
          ),
          label: Text('References (${citations.length})'),
          style: OutlinedButton.styleFrom(
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            side: BorderSide(
              color: scheme.outlineVariant.withValues(alpha: 0.8),
            ),
          ),
        ),
        _OverlappingReferenceChips(
          citations: citations,
          onTapCitation: onTapCitation,
          onTapMore: onToggle,
        ),
      ],
    );
  }
}

class _OverlappingReferenceChips extends StatelessWidget {
  const _OverlappingReferenceChips({
    required this.citations,
    required this.onTapCitation,
    required this.onTapMore,
  });

  static const _chipSize = 28.0;
  static const _step = 17.0;
  static const _maxVisible = 6;

  final List<Citation> citations;
  final ValueChanged<Citation> onTapCitation;
  final VoidCallback onTapMore;

  @override
  Widget build(BuildContext context) {
    final visibleCount = citations.length > _maxVisible
        ? _maxVisible - 1
        : citations.length;
    final hiddenCount = citations.length - visibleCount;
    final width = citations.isEmpty
        ? 0.0
        : _chipSize +
              ((visibleCount - 1) * _step) +
              (hiddenCount > 0 ? _step : 0);

    return SizedBox(
      width: width,
      height: _chipSize,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          for (var i = 0; i < visibleCount; i++)
            Positioned(
              left: i * _step,
              child: _RoundReferenceChip(
                citation: citations[i],
                size: _chipSize,
                onTap: () => onTapCitation(citations[i]),
              ),
            ),
          if (hiddenCount > 0)
            Positioned(
              left: visibleCount * _step,
              child: _MoreReferenceChip(
                count: hiddenCount,
                size: _chipSize,
                onTap: onTapMore,
              ),
            ),
        ],
      ),
    );
  }
}

class _RoundReferenceChip extends StatelessWidget {
  const _RoundReferenceChip({
    required this.citation,
    required this.size,
    required this.onTap,
  });

  final Citation citation;
  final double size;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isLog = citation.kind == CitationKind.log;
    final accent = isLog ? scheme.primary : scheme.tertiary;
    final foreground = isLog ? scheme.onPrimary : scheme.onTertiary;
    return Tooltip(
      message: citation.marker,
      child: Material(
        color: accent,
        shape: CircleBorder(side: BorderSide(color: scheme.surface, width: 2)),
        child: InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          child: SizedBox.square(
            dimension: size,
            child: Center(
              child: Text(
                citation.marker.substring(1, citation.marker.length - 1),
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  color: foreground,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MoreReferenceChip extends StatelessWidget {
  const _MoreReferenceChip({
    required this.count,
    required this.size,
    required this.onTap,
  });

  final int count;
  final double size;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: 'Show $count more reference(s)',
      child: Material(
        color: scheme.surfaceContainerHighest,
        shape: CircleBorder(side: BorderSide(color: scheme.surface, width: 2)),
        child: InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          child: SizedBox.square(
            dimension: size,
            child: Center(
              child: Text(
                '+$count',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

List<Citation> _referencesFor(AskChatMessage message) {
  final seen = <String>{};
  final citations = <Citation>[];
  for (final citation in parseCitations(message.text)) {
    if (!_hasHitForCitation(message, citation)) continue;
    if (seen.add(citation.marker)) citations.add(citation);
  }
  if (citations.isNotEmpty) return citations;

  for (var i = 0; i < message.memoryHits.length; i++) {
    citations.add(Citation(kind: CitationKind.memory, index: i + 1));
  }
  for (var i = 0; i < message.logHits.length; i++) {
    citations.add(Citation(kind: CitationKind.log, index: i + 1));
  }
  return citations;
}

bool _hasHitForCitation(AskChatMessage message, Citation citation) {
  final hitCount = citation.kind == CitationKind.log
      ? message.logHits.length
      : message.memoryHits.length;
  return citation.index > 0 && citation.index <= hitCount;
}
