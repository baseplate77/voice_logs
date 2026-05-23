import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import 'ask_citation_parser.dart';

/// Renders an assistant answer as lightweight Markdown with tappable inline
/// citation chips. Supported Markdown intentionally mirrors the answer prompt:
/// headings, paragraphs, bullets, simple pipe tables, inline **bold**, inline
/// `code`, and `[L#]` / `[M#]` citation chips.
class AskAnswerView extends StatelessWidget {
  const AskAnswerView({
    super.key,
    required this.text,
    required this.onTapCitation,
    this.showInlineCitations = true,
  });

  /// The full assistant answer including `[L#]` / `[M#]` markers.
  final String text;

  /// Invoked when the user taps a citation chip. The cite supplies the
  /// kind + 1-based index; the caller dereferences against the message's
  /// `logHits` / `memoryHits`.
  final ValueChanged<Citation> onTapCitation;

  /// Whether `[L#]` / `[M#]` markers should be rendered inline with the
  /// answer text. Chat bubbles hide them and show reference chips below the
  /// answer instead; tests and standalone previews keep the old behavior by
  /// default.
  final bool showInlineCitations;

  @override
  Widget build(BuildContext context) {
    final displayText = showInlineCitations
        ? text
        : _hideInlineCitationMarkers(text);
    if (displayText.trim().isEmpty) return const SizedBox.shrink();
    return _MarkdownAnswerBody(text: displayText, onTapCitation: onTapCitation);
  }
}

class _MarkdownAnswerBody extends StatelessWidget {
  const _MarkdownAnswerBody({required this.text, required this.onTapCitation});

  final String text;
  final ValueChanged<Citation> onTapCitation;

  @override
  Widget build(BuildContext context) {
    final blocks = _buildBlocks(context);
    return SelectionArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: blocks.isEmpty ? [const SizedBox.shrink()] : blocks,
      ),
    );
  }

  List<Widget> _buildBlocks(BuildContext context) {
    final blocks = <Widget>[];
    var offset = 0;
    while (offset < text.length) {
      final line = _lineAt(text, offset);
      if (line.content.trim().isEmpty) {
        blocks.add(SizedBox(height: 8.h));
        offset = line.nextOffset;
        continue;
      }

      final table = _tableAt(offset);
      if (table != null) {
        blocks.add(
          _MarkdownAnswerTable(rows: table.rows, onTapCitation: onTapCitation),
        );
        blocks.add(SizedBox(height: 12.h));
        offset = table.nextOffset;
        continue;
      }

      final heading = _headingMatch(line.content);
      if (heading != null) {
        // Section headers act as labels, not page titles. A compact
        // letter-spaced label reads better than a heavy h2 inside a chat
        // bubble and keeps the answer feeling like a single unit.
        blocks.add(
          Padding(
            padding: EdgeInsets.only(top: blocks.isEmpty ? 0 : 8, bottom: 4.h),
            child: RichText(
              text: _inlineSpan(
                context,
                heading.content,
                style: _headingStyle(context, heading.level),
                onTapCitation: onTapCitation,
              ),
            ),
          ),
        );
        offset = line.nextOffset;
        continue;
      }

      final bullet = _bulletMatch(line.content);
      if (bullet != null) {
        blocks.add(
          Padding(
            padding: EdgeInsets.only(bottom: 4.h),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 18.w,
                  child: Text(bullet.marker, style: _bodyStyle(context)),
                ),
                Expanded(
                  child: RichText(
                    text: _inlineSpan(
                      context,
                      bullet.content,
                      onTapCitation: onTapCitation,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
        offset = line.nextOffset;
        continue;
      }

      final paragraph = _paragraphAt(offset);
      blocks.add(
        Padding(
          padding: EdgeInsets.only(bottom: 8.h),
          child: RichText(
            text: _inlineSpan(
              context,
              paragraph.text,
              onTapCitation: onTapCitation,
            ),
          ),
        ),
      );
      offset = paragraph.nextOffset;
    }
    return blocks;
  }

  _Paragraph _paragraphAt(int start) {
    var end = start;
    var cursor = start;
    while (cursor < text.length) {
      final line = _lineAt(text, cursor);
      if (line.content.trim().isEmpty) break;
      if (_headingMatch(line.content) != null) break;
      if (_bulletMatch(line.content) != null) break;
      if (_tableAt(cursor) != null) break;
      end = line.end;
      cursor = line.nextOffset;
    }
    if (end <= start) {
      final line = _lineAt(text, start);
      return _Paragraph(text: line.content, nextOffset: line.nextOffset);
    }
    return _Paragraph(text: text.substring(start, end), nextOffset: cursor);
  }

  _TableBlock? _tableAt(int start) {
    final first = _lineAt(text, start);
    if (!_looksLikeTableRow(first.content)) return null;
    if (first.nextOffset >= text.length) return null;
    final second = _lineAt(text, first.nextOffset);
    if (!_isTableSeparator(second.content)) return null;

    final rows = <List<String>>[_splitTableCells(first.content)];
    var cursor = second.nextOffset;
    while (cursor < text.length) {
      final line = _lineAt(text, cursor);
      if (!_looksLikeTableRow(line.content)) break;
      rows.add(_splitTableCells(line.content));
      cursor = line.nextOffset;
    }
    return _TableBlock(rows: rows, nextOffset: cursor);
  }
}

class _MarkdownAnswerTable extends StatelessWidget {
  const _MarkdownAnswerTable({required this.rows, required this.onTapCitation});

  final List<List<String>> rows;
  final ValueChanged<Citation> onTapCitation;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final maxColumns = rows.fold<int>(
      0,
      (max, row) => row.length > max ? row.length : max,
    );
    final normalized = rows
        .map(
          (row) => [...row, for (var i = row.length; i < maxColumns; i++) ''],
        )
        .toList();

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Table(
        defaultColumnWidth: const IntrinsicColumnWidth(),
        border: TableBorder.all(color: colorScheme.outlineVariant),
        children: [
          for (var rowIndex = 0; rowIndex < normalized.length; rowIndex++)
            TableRow(
              decoration: rowIndex == 0
                  ? BoxDecoration(color: colorScheme.surfaceContainerHighest)
                  : null,
              children: [
                for (final cell in normalized[rowIndex])
                  Padding(
                    padding: EdgeInsets.all(8.r),
                    child: RichText(
                      text: _inlineSpan(
                        context,
                        cell,
                        style: rowIndex == 0
                            ? _bodyStyle(
                                context,
                              ).copyWith(fontWeight: FontWeight.w700)
                            : _bodyStyle(context),
                        onTapCitation: onTapCitation,
                      ),
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

TextSpan _inlineSpan(
  BuildContext context,
  String text, {
  TextStyle? style,
  required ValueChanged<Citation> onTapCitation,
}) {
  final base = style ?? _bodyStyle(context);
  final children = <InlineSpan>[];
  for (final run in tokenizeAnswer(text)) {
    switch (run) {
      case TextRun(:final text):
        children.addAll(_inlineMarkdownTextSpans(text, base));
      case CitationRun(:final citation):
        children.add(
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: _CitationChip(
              citation: citation,
              onTap: () => onTapCitation(citation),
            ),
          ),
        );
    }
  }
  return TextSpan(style: base, children: children);
}

List<TextSpan> _inlineMarkdownTextSpans(String text, TextStyle base) {
  final spans = <TextSpan>[];
  final pattern = RegExp(r'(\*\*([^*]+)\*\*)|(`([^`]+)`)');
  var cursor = 0;
  for (final match in pattern.allMatches(text)) {
    if (match.start > cursor) {
      spans.add(TextSpan(text: text.substring(cursor, match.start)));
    }
    final bold = match.group(2);
    final code = match.group(4);
    if (bold != null) {
      spans.add(
        TextSpan(
          text: bold,
          style: base.copyWith(fontWeight: FontWeight.w700),
        ),
      );
    } else if (code != null) {
      spans.add(
        TextSpan(
          text: code,
          style: base.copyWith(
            fontFamily: 'IBMPlexMono',
            backgroundColor: Colors.black.withValues(alpha: 0.08),
          ),
        ),
      );
    }
    cursor = match.end;
  }
  if (cursor < text.length) spans.add(TextSpan(text: text.substring(cursor)));
  return spans;
}

TextStyle _bodyStyle(BuildContext context) {
  return Theme.of(context).textTheme.bodyMedium?.copyWith(height: 1.45) ??
      TextStyle(fontSize: 15.sp, height: 1.45);
}

TextStyle _headingStyle(BuildContext context, int level) {
  // Inside a chat bubble we want headings to read as section labels, not
  // page titles. Drop a couple of steps in the scale and lean on weight +
  // a touch of letter spacing to keep them readable without dominating.
  final theme = Theme.of(context);
  final base = switch (level) {
    1 => theme.textTheme.titleSmall,
    2 => theme.textTheme.labelLarge,
    _ => theme.textTheme.labelMedium,
  };
  return (base ?? _bodyStyle(context)).copyWith(
    fontWeight: FontWeight.w700,
    letterSpacing: 0.4,
    color: theme.colorScheme.onSurfaceVariant,
  );
}

class _CitationChip extends StatelessWidget {
  const _CitationChip({required this.citation, required this.onTap});

  final Citation citation;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isLog = citation.kind == CitationKind.log;
    final scheme = Theme.of(context).colorScheme;
    final background = isLog ? scheme.primary : scheme.tertiary;
    final foreground = isLog ? scheme.onPrimary : scheme.onTertiary;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 2.w),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10.r),
        child: Container(
          padding: EdgeInsets.symmetric(horizontal: 6.w, vertical: 1.h),
          decoration: BoxDecoration(
            color: background.withValues(alpha: 0.18),
            borderRadius: BorderRadius.circular(10.r),
          ),
          child: Text(
            citation.marker,
            style: TextStyle(
              fontSize: 12.sp,
              fontWeight: FontWeight.w600,
              color: foreground.computeLuminance() > 0.5
                  ? scheme.onSurface
                  : background,
            ),
          ),
        ),
      ),
    );
  }
}

_Line _lineAt(String text, int start) {
  final newline = text.indexOf('\n', start);
  final end = newline < 0 ? text.length : newline;
  return _Line(
    content: text.substring(start, end),
    end: end,
    nextOffset: newline < 0 ? text.length : newline + 1,
  );
}

_Heading? _headingMatch(String line) {
  final match = RegExp(r'^\s*(#{1,3})\s+(.+)$').firstMatch(line);
  if (match == null) return null;
  return _Heading(level: match.group(1)!.length, content: match.group(2)!);
}

_Bullet? _bulletMatch(String line) {
  final match = RegExp(r'^\s*((?:[-*+])|(?:\d+[.)]))\s+(.+)$').firstMatch(line);
  if (match == null) return null;
  return _Bullet(
    marker: match.group(1)!.startsWith(RegExp(r'\d')) ? match.group(1)! : '•',
    content: match.group(2)!,
  );
}

bool _looksLikeTableRow(String line) {
  final trimmed = line.trim();
  return trimmed.contains('|') && trimmed.split('|').length >= 3;
}

bool _isTableSeparator(String line) {
  final cells = _splitTableCells(line);
  if (cells.isEmpty) return false;
  return cells.every((cell) => RegExp(r'^:?-{3,}:?$').hasMatch(cell.trim()));
}

List<String> _splitTableCells(String line) {
  var trimmed = line.trim();
  if (trimmed.startsWith('|')) trimmed = trimmed.substring(1);
  if (trimmed.endsWith('|')) trimmed = trimmed.substring(0, trimmed.length - 1);
  return trimmed.split('|').map((cell) => cell.trim()).toList();
}

String _hideInlineCitationMarkers(String answer) {
  var cleaned = answer.replaceAll(RegExp(r'[ \t]*\[(?:L|M)\d+\]'), '');
  cleaned = cleaned.replaceAllMapped(
    RegExp(r'[ \t]+([,.;:!?])'),
    (match) => match.group(1)!,
  );
  cleaned = cleaned.replaceAll(RegExp(r'[ \t]{2,}'), ' ');
  cleaned = cleaned.replaceAll(RegExp(r'\n{3,}'), '\n\n');
  return cleaned.trimRight();
}

class _Line {
  _Line({required this.content, required this.end, required this.nextOffset});

  final String content;
  final int end;
  final int nextOffset;
}

class _Heading {
  _Heading({required this.level, required this.content});

  final int level;
  final String content;
}

class _Paragraph {
  _Paragraph({required this.text, required this.nextOffset});

  final String text;
  final int nextOffset;
}

class _Bullet {
  _Bullet({required this.marker, required this.content});

  final String marker;
  final String content;
}

class _TableBlock {
  _TableBlock({required this.rows, required this.nextOffset});

  final List<List<String>> rows;
  final int nextOffset;
}
