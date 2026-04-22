/// A chunk of a voice log ready for embedding. Each segment is
/// embedded independently and stored with a foreign key back to the
/// parent log so vector search can locate intra-log passages.
class TextSegment {
  const TextSegment({
    required this.logId,
    required this.index,
    required this.text,
  });

  /// Parent voice log id.
  final String logId;

  /// Zero-based position within the log.
  final int index;

  /// The chunk text (no `"passage: "` prefix — the embedder adds it).
  final String text;
}

/// Rough word-based segmenter. Not tokenizer-aware — but e5's 512-token
/// window is generous enough for ~300 words per chunk. Keeps adjacent
/// sentences together by preferring to break on `.`/`?`/`!` boundaries.
///
/// Returns at least one segment per non-empty log, even when the text
/// is under [targetWords] long.
List<TextSegment> segmentByWords(
  String logId,
  String text, {
  int targetWords = 200,
  int overlapWords = 20,
}) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) {
    return [TextSegment(logId: logId, index: 0, text: '')];
  }
  final words = trimmed.split(RegExp(r'\s+'));
  if (words.length <= targetWords) {
    return [TextSegment(logId: logId, index: 0, text: trimmed)];
  }

  final segments = <TextSegment>[];
  var start = 0;
  var idx = 0;
  while (start < words.length) {
    final end = (start + targetWords).clamp(0, words.length);
    final slice = words.sublist(start, end).join(' ');
    segments.add(TextSegment(logId: logId, index: idx, text: slice));
    if (end >= words.length) break;
    start = (end - overlapWords).clamp(0, words.length);
    idx++;
  }
  return segments;
}
