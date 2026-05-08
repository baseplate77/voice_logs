import 'offset_recovery.dart';

/// A raw transcript slice sized to fit into Gemma's context window.
class LlmTextChunk {
  const LlmTextChunk({required this.index, required this.text});

  /// Zero-based chunk index.
  final int index;

  /// Raw transcript text for this chunk.
  final String text;
}

/// A parsed/refined chunk before it is stitched back into the full log.
class RefinedTextChunk {
  const RefinedTextChunk({
    required this.index,
    required this.cleanedText,
    required this.mentions,
  });

  /// Zero-based chunk index matching [LlmTextChunk.index].
  final int index;

  /// Gemma-cleaned text for this chunk.
  final String cleanedText;

  /// Entity mentions recovered against [cleanedText].
  final List<LocatedMention> mentions;
}

/// Full cleaned transcript plus entity offsets after stitching chunks.
class StitchedRefinement {
  const StitchedRefinement({required this.cleanedText, required this.mentions});

  /// Stitched cleaned transcript.
  final String cleanedText;

  /// Mentions adjusted to [cleanedText] offsets.
  final List<LocatedMention> mentions;
}

/// Split raw transcript into LLM-safe word windows.
///
/// Gemma 4 E2B's current bundle is capped at 2048 tokens. Refinement must
/// leave room for prompt instructions and the JSON response, so raw transcript
/// chunks are intentionally much smaller than the full context window.
List<LlmTextChunk> splitForLlmRefine(
  String text, {
  int targetWords = 450,
  int overlapWords = 50,
}) {
  if (targetWords <= 0) {
    throw ArgumentError.value(targetWords, 'targetWords', 'must be positive');
  }
  if (overlapWords < 0 || overlapWords >= targetWords) {
    throw ArgumentError.value(
      overlapWords,
      'overlapWords',
      'must be >= 0 and < targetWords',
    );
  }

  final trimmed = text.trim();
  if (trimmed.isEmpty) return const [];
  final words = trimmed.split(RegExp(r'\s+'));
  if (words.length <= targetWords) {
    return [LlmTextChunk(index: 0, text: trimmed)];
  }

  final chunks = <LlmTextChunk>[];
  var start = 0;
  var index = 0;
  while (start < words.length) {
    final end = (start + targetWords).clamp(0, words.length);
    chunks.add(
      LlmTextChunk(index: index, text: words.sublist(start, end).join(' ')),
    );
    if (end >= words.length) break;
    start = end - overlapWords;
    index++;
  }
  return chunks;
}

/// Stitch independently refined chunks into one cleaned transcript.
///
/// Overlap is removed by comparing normalized word suffixes/prefixes. Mentions
/// that fall wholly inside a removed overlap are dropped; mentions in retained
/// text are shifted to their final global offsets.
StitchedRefinement stitchRefinedChunks(
  List<RefinedTextChunk> chunks, {
  int maxOverlapWords = 80,
  int minOverlapWordsToDrop = 5,
}) {
  if (chunks.isEmpty) {
    return const StitchedRefinement(cleanedText: '', mentions: []);
  }
  final ordered = [...chunks]..sort((a, b) => a.index.compareTo(b.index));
  final out = StringBuffer();
  final mentions = <LocatedMention>[];

  for (final chunk in ordered) {
    final cleaned = chunk.cleanedText.trim();
    if (cleaned.isEmpty) continue;

    final dropPrefixChars = out.isEmpty
        ? 0
        : _overlapPrefixCharsToDrop(
            out.toString(),
            cleaned,
            maxOverlapWords: maxOverlapWords,
            minOverlapWordsToDrop: minOverlapWordsToDrop,
          );
    final kept = cleaned.substring(dropPrefixChars).trimLeft();
    final trimLeftChars = cleaned.length - dropPrefixChars - kept.length;
    final totalDropped = dropPrefixChars + trimLeftChars;
    if (kept.isEmpty) continue;

    if (out.isNotEmpty) out.write(' ');
    final globalStart = out.length;
    out.write(kept);

    for (final mention in chunk.mentions) {
      if (mention.charEnd <= totalDropped) continue;
      if (mention.charStart < totalDropped) continue;
      final start = globalStart + mention.charStart - totalDropped;
      final end = globalStart + mention.charEnd - totalDropped;
      if (start < globalStart || end > globalStart + kept.length) continue;
      mentions.add(
        LocatedMention(
          text: kept.substring(start - globalStart, end - globalStart),
          type: mention.type,
          charStart: start,
          charEnd: end,
        ),
      );
    }
  }

  return StitchedRefinement(cleanedText: out.toString(), mentions: mentions);
}

int _overlapPrefixCharsToDrop(
  String previous,
  String current, {
  required int maxOverlapWords,
  required int minOverlapWordsToDrop,
}) {
  final prevWords = _wordSpans(previous);
  final currentWords = _wordSpans(current);
  final max = [
    maxOverlapWords,
    prevWords.length,
    currentWords.length,
  ].reduce((a, b) => a < b ? a : b);
  for (var count = max; count >= minOverlapWordsToDrop; count--) {
    final prevSuffix = prevWords
        .skip(prevWords.length - count)
        .map((w) => w.normalized)
        .toList(growable: false);
    final currentPrefix = currentWords
        .take(count)
        .map((w) => w.normalized)
        .toList(growable: false);
    if (_sameWords(prevSuffix, currentPrefix)) {
      return currentWords[count - 1].end;
    }
  }
  return 0;
}

List<({int start, int end, String normalized})> _wordSpans(String text) {
  return RegExp(r'\S+')
      .allMatches(text)
      .map((m) {
        return (
          start: m.start,
          end: m.end,
          normalized: _normalizeWord(text.substring(m.start, m.end)),
        );
      })
      .where((w) => w.normalized.isNotEmpty)
      .toList(growable: false);
}

String _normalizeWord(String word) {
  return word.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
}

bool _sameWords(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
