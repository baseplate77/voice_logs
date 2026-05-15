/// Citation tokens emitted by the Ask prompt template — see
/// `ask_prompt_templates.dart`. The LLM is instructed to inline
/// `[L1]`/`[L2]` for voice-log hits and `[M1]`/`[M2]` for memory cards.
enum CitationKind { log, memory }

/// One inline citation marker inside an assistant answer.
class Citation {
  const Citation({required this.kind, required this.index});

  /// Whether the citation points at a voice-log or memory hit.
  final CitationKind kind;

  /// One-based index into the corresponding `logHits` / `memoryHits` list
  /// attached to the assistant message. `[L2]` → index `2`.
  final int index;

  /// The string the LLM emitted, e.g. `[L1]`.
  String get marker => switch (kind) {
    CitationKind.log => '[L$index]',
    CitationKind.memory => '[M$index]',
  };

  /// Zero-based offset into the parent `hits` list.
  int get hitOffset => index - 1;
}

/// One run of the parsed answer text — either plain prose or a citation
/// marker. Renderers walk a list of these to build their span tree.
sealed class AnswerRun {
  const AnswerRun();
}

/// Plain-text run.
final class TextRun extends AnswerRun {
  const TextRun(this.text);
  final String text;
}

/// Citation marker run.
final class CitationRun extends AnswerRun {
  const CitationRun(this.citation);
  final Citation citation;
}

/// Match `[L1]`, `[L23]`, `[M4]`, etc. The index is captured separately
/// from the kind so we can build a typed [Citation] without re-parsing.
final RegExp _citationPattern = RegExp(r'\[([LM])(\d+)\]');

/// Split [answer] into a list of [TextRun] / [CitationRun] entries in
/// source order. Adjacent text runs are kept separate by design so the
/// caller can decide whether to merge or wrap them in different widgets.
///
/// Malformed tokens (e.g. `[L]`, `[L0]`, missing brackets) stay as plain
/// text — the regex only matches digits, and a zero-indexed citation is
/// downgraded to text by [parseCitations].
List<AnswerRun> tokenizeAnswer(String answer) {
  if (answer.isEmpty) return const [];
  final runs = <AnswerRun>[];
  var cursor = 0;
  for (final match in _citationPattern.allMatches(answer)) {
    final indexStr = match.group(2)!;
    final index = int.parse(indexStr);
    if (index < 1) continue; // [L0] / [M0] aren't valid one-based indices.
    if (match.start > cursor) {
      runs.add(TextRun(answer.substring(cursor, match.start)));
    }
    final kind = match.group(1) == 'L' ? CitationKind.log : CitationKind.memory;
    runs.add(CitationRun(Citation(kind: kind, index: index)));
    cursor = match.end;
  }
  if (cursor < answer.length) {
    runs.add(TextRun(answer.substring(cursor)));
  }
  return runs;
}

/// Flat list of every citation found in [answer], in source order.
/// Duplicates are preserved so callers can render the same source multiple
/// times if the LLM cited it more than once.
List<Citation> parseCitations(String answer) {
  return tokenizeAnswer(
    answer,
  ).whereType<CitationRun>().map((r) => r.citation).toList(growable: false);
}
