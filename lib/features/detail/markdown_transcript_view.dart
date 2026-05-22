import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../core/db/repositories/entity_mention_repository.dart';

/// Renders refined transcripts as lightweight Markdown while preserving entity
/// highlights for paragraph and bullet text.
class MarkdownTranscriptView extends StatelessWidget {
  const MarkdownTranscriptView({
    super.key,
    required this.text,
    required this.mentions,
  });

  final String text;
  final List<EntityMentionView> mentions;

  @override
  Widget build(BuildContext context) {
    final blocks = _buildBlocks(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: blocks.isEmpty ? [const SizedBox.shrink()] : blocks,
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
        blocks.add(_MarkdownTable(rows: table.rows));
        blocks.add(SizedBox(height: 12.h));
        offset = table.nextOffset;
        continue;
      }

      final bullet = _bulletMatch(line.content);
      if (bullet != null) {
        blocks.add(
          Padding(
            padding: EdgeInsets.only(bottom: 6.h),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 24.w,
                  child: Text(
                    bullet.marker,
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      fontFamily: 'JetBrainsMono',
                    ),
                  ),
                ),
                Expanded(
                  child: SelectableText.rich(
                    _highlightedSpan(
                      context,
                      bullet.content,
                      line.start + bullet.contentStart,
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
          padding: EdgeInsets.only(bottom: 12.h),
          child: SelectableText.rich(
            _highlightedSpan(context, paragraph.text, paragraph.start),
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
      if (_bulletMatch(line.content) != null) break;
      if (_tableAt(cursor) != null) break;
      end = line.end;
      cursor = line.nextOffset;
    }
    if (end <= start) {
      final line = _lineAt(text, start);
      return _Paragraph(
        text: line.content,
        start: line.start,
        nextOffset: line.nextOffset,
      );
    }
    return _Paragraph(
      text: text.substring(start, end),
      start: start,
      nextOffset: cursor,
    );
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

  TextSpan _highlightedSpan(
    BuildContext context,
    String segment,
    int globalStart,
  ) {
    final base =
        Theme.of(context).textTheme.bodyLarge?.copyWith(
          height: 1.5,
          fontFamily: 'JetBrainsMono',
        ) ??
        TextStyle(fontSize: 16.sp, height: 1.5, fontFamily: 'JetBrainsMono');
    final highlightStyle = base.copyWith(
      backgroundColor: Theme.of(context).colorScheme.tertiaryContainer,
      color: Theme.of(context).colorScheme.onTertiaryContainer,
      fontWeight: FontWeight.w600,
      fontFamily: 'JetBrainsMono',
    );

    final globalEnd = globalStart + segment.length;
    final sorted =
        mentions
            .where((m) => m.charEnd > globalStart && m.charStart < globalEnd)
            .toList()
          ..sort((a, b) => a.charStart.compareTo(b.charStart));
    final children = <TextSpan>[];
    var cursor = 0;
    for (final mention in sorted) {
      final localStart = (mention.charStart - globalStart).clamp(
        0,
        segment.length,
      );
      final localEnd = (mention.charEnd - globalStart).clamp(0, segment.length);
      if (localStart < cursor || localStart >= localEnd) continue;
      if (localStart > cursor) {
        children.add(TextSpan(text: segment.substring(cursor, localStart)));
      }
      children.add(
        TextSpan(
          text: segment.substring(localStart, localEnd),
          style: highlightStyle,
        ),
      );
      cursor = localEnd;
    }
    if (cursor < segment.length) {
      children.add(TextSpan(text: segment.substring(cursor)));
    }
    return TextSpan(style: base, children: children);
  }
}

class _MarkdownTable extends StatelessWidget {
  const _MarkdownTable({required this.rows});

  final List<List<String>> rows;

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
                    child: SelectableText(
                      cell,
                      style:
                          (rowIndex == 0
                                  ? const TextStyle(fontWeight: FontWeight.w600)
                                  : const TextStyle())
                              .copyWith(fontFamily: 'JetBrainsMono'),
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

_Line _lineAt(String text, int start) {
  final newline = text.indexOf('\n', start);
  final end = newline < 0 ? text.length : newline;
  return _Line(
    content: text.substring(start, end),
    start: start,
    end: end,
    nextOffset: newline < 0 ? text.length : newline + 1,
  );
}

_Bullet? _bulletMatch(String line) {
  final match = RegExp(r'^\s*((?:[-*+])|(?:\d+[.)]))\s+(.+)$').firstMatch(line);
  if (match == null) return null;
  final content = match.group(2)!;
  return _Bullet(
    marker: match.group(1)!.startsWith(RegExp(r'\d')) ? match.group(1)! : '•',
    content: content,
    contentStart: line.indexOf(content),
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

class _Line {
  _Line({
    required this.content,
    required this.start,
    required this.end,
    required this.nextOffset,
  });

  final String content;
  final int start;
  final int end;
  final int nextOffset;
}

class _Paragraph {
  _Paragraph({
    required this.text,
    required this.start,
    required this.nextOffset,
  });

  final String text;
  final int start;
  final int nextOffset;
}

class _Bullet {
  _Bullet({
    required this.marker,
    required this.content,
    required this.contentStart,
  });

  final String marker;
  final String content;
  final int contentStart;
}

class _TableBlock {
  _TableBlock({required this.rows, required this.nextOffset});

  final List<List<String>> rows;
  final int nextOffset;
}
