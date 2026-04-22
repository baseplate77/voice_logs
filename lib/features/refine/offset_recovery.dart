/// One entity mention with its `[start, end)` character offsets into
/// the cleaned text.
class LocatedMention {
  const LocatedMention({
    required this.text,
    required this.type,
    required this.charStart,
    required this.charEnd,
  });

  final String text;
  final String type;
  final int charStart;
  final int charEnd;
}

/// Given the model's cleaned text and the list of (surface, type)
/// mentions it extracted, recover `[start, end)` offsets by scanning
/// forward through [cleanedText]. Skips mentions whose surface form
/// doesn't appear — malformed LLM output shouldn't fail the whole log.
///
/// Each call advances a single cursor so repeated mentions map to
/// distinct occurrences — "Shivani" appearing twice yields two mentions
/// with different offsets.
List<LocatedMention> recoverOffsets({
  required String cleanedText,
  required List<({String text, String type})> mentions,
}) {
  final out = <LocatedMention>[];
  final lower = cleanedText.toLowerCase();
  var cursor = 0;
  for (final m in mentions) {
    final needle = m.text.toLowerCase();
    if (needle.isEmpty) continue;
    final idx = lower.indexOf(needle, cursor);
    if (idx < 0) {
      // Fall back to a non-cursor global search — entities don't always
      // appear in order in the LLM's list.
      final global = lower.indexOf(needle);
      if (global < 0) continue;
      out.add(
        LocatedMention(
          text: cleanedText.substring(global, global + m.text.length),
          type: m.type,
          charStart: global,
          charEnd: global + m.text.length,
        ),
      );
      continue;
    }
    out.add(
      LocatedMention(
        text: cleanedText.substring(idx, idx + m.text.length),
        type: m.type,
        charStart: idx,
        charEnd: idx + m.text.length,
      ),
    );
    cursor = idx + m.text.length;
  }
  return out;
}
