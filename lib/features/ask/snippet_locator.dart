import '../../core/db/repositories/transcript_segment_repository.dart';

/// Time range derived from a search-hit snippet — what the Ask flow
/// passes to LogDetailScreen so it can jump to the moment a citation was
/// quoted from.
class SnippetLocation {
  const SnippetLocation({
    required this.startMs,
    required this.endMs,
    required this.matchedText,
  });

  final int startMs;
  final int endMs;
  final String matchedText;
}

/// Find the first [TranscriptSegmentView] whose text contains [snippet]
/// (case-insensitive, whitespace-collapsed). Returns null when nothing
/// matches — caller should fall back to opening the log without a seek.
///
/// The hybrid retriever's snippet is text from the *refined* transcript,
/// whereas segments hold the *raw* STT output, so an exact match is the
/// exception, not the rule. We try in this order:
///   1. Direct substring match on normalized text.
///   2. Longest-window substring (first 24 chars of the snippet) — handles
///      the common case where the refined snippet is a paraphrase of the
///      raw segment with the first few words preserved.
///   3. Bail to null.
SnippetLocation? locateSnippet({
  required String snippet,
  required List<TranscriptSegmentView> segments,
}) {
  if (segments.isEmpty || snippet.trim().isEmpty) return null;
  final needle = _normalize(snippet);
  if (needle.isEmpty) return null;

  for (final seg in segments) {
    final hay = _normalize(seg.text);
    if (hay.contains(needle)) {
      return SnippetLocation(
        startMs: seg.startMs,
        endMs: seg.endMs,
        matchedText: seg.text,
      );
    }
  }

  // Fallback: try a short leading window. This handles the case where the
  // refined snippet starts with the same phrase as the raw segment but
  // diverges later.
  const windowChars = 24;
  if (needle.length > windowChars) {
    final window = needle.substring(0, windowChars);
    for (final seg in segments) {
      if (_normalize(seg.text).contains(window)) {
        return SnippetLocation(
          startMs: seg.startMs,
          endMs: seg.endMs,
          matchedText: seg.text,
        );
      }
    }
  }

  return null;
}

/// Case-insensitive, whitespace-collapsed normalization for substring
/// matching. Punctuation is preserved because the refine step sometimes
/// adds it and we want those snippets to still match raw segments that
/// happen to contain identical phrases.
String _normalize(String input) {
  return input.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();
}
