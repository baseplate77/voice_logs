/// Runtime guard for the Ask streaming output.
///
/// The 1B local model is prone to phrase loops — getting stuck on a sentence
/// like "This editing process involves an actor as an actor." and repeating
/// it until the context window fills. Without consumer-side intervention the
/// stream runs to the model's own EOS, which can be thousands of duplicate
/// tokens away. This guard watches the running answer after every delta and
/// signals when:
///   * the answer has crossed a hard character cap, or
///   * the tail of the answer contains a short word-level n-gram repeated at
///     least [maxRepeats] times back-to-back (the exact failure mode in the
///     screenshot from the bug report).
///
/// The caller stops forwarding deltas and appends a small truncation marker
/// so users see the cut-off was deliberate.
class AskStreamGuard {
  AskStreamGuard({
    this.maxAnswerChars = 3500,
    this.minNgramWords = 3,
    this.maxNgramWords = 12,
    this.maxRepeats = 3,
  });

  /// Hard ceiling on total streamed characters. Backstop in case the
  /// repetition detector misses an unusual loop pattern.
  final int maxAnswerChars;

  /// Smallest n-gram length (in words) the repetition detector considers.
  final int minNgramWords;

  /// Largest n-gram length (in words) the repetition detector considers.
  /// Phrases longer than this are unlikely to be exact loops worth catching.
  final int maxNgramWords;

  /// Number of consecutive repeats of the same n-gram that count as a loop.
  final int maxRepeats;

  /// Marker appended to the answer when the guard trips. Kept short and
  /// parenthetical so it doesn't break Markdown rendering.
  static const truncationMarker =
      '\n\n_(response truncated — model started repeating itself)_';

  /// Inspect [running], the full answer accumulated so far. Returns a reason
  /// when generation should stop, or null when the answer should keep
  /// streaming.
  AskStreamGuardTrip? inspect(String running) {
    if (running.length >= maxAnswerChars) {
      return AskStreamGuardTrip.charCap;
    }
    if (_hasLoopingTail(running)) {
      return AskStreamGuardTrip.repetition;
    }
    return null;
  }

  bool _hasLoopingTail(String text) {
    final words = _tailWords(text);
    if (words.length < minNgramWords * maxRepeats) return false;

    // Try the largest n-gram first so a long phrase loop (e.g. "involves
    // an actor as an actor", 6 words) is matched in its natural length
    // rather than fragmented into a shorter spurious match.
    final upper = maxNgramWords < words.length ~/ maxRepeats
        ? maxNgramWords
        : words.length ~/ maxRepeats;
    for (var n = upper; n >= minNgramWords; n--) {
      if (_tailRepeatsAtLeast(words, n, maxRepeats)) return true;
    }
    return false;
  }

  /// Returns the last `~maxNgramWords * maxRepeats * 2` words of [text].
  /// We only need enough words to detect the deepest loop the guard cares
  /// about — anything further back is irrelevant once the tail has flipped
  /// into a loop pattern.
  List<String> _tailWords(String text) {
    final budget = maxNgramWords * maxRepeats * 2;
    // Lowercase + strip punctuation so capitalization and trailing dots
    // don't break the comparison.
    final tokens = RegExp(
      r"[A-Za-z0-9]+(?:'[A-Za-z0-9]+)?",
    ).allMatches(text).map((m) => m.group(0)!.toLowerCase()).toList();
    if (tokens.length <= budget) return tokens;
    return tokens.sublist(tokens.length - budget);
  }

  /// True when the final [n] words of [words] are repeated at least
  /// [repeats] times back-to-back (`...ABC ABC ABC` for n=3, repeats=3).
  bool _tailRepeatsAtLeast(List<String> words, int n, int repeats) {
    if (words.length < n * repeats) return false;
    final start = words.length - n;
    for (var copy = 1; copy < repeats; copy++) {
      final from = start - n * copy;
      if (from < 0) return false;
      for (var i = 0; i < n; i++) {
        if (words[start + i] != words[from + i]) return false;
      }
    }
    return true;
  }
}

/// Why the stream guard fired. Surfaced to the caller so future telemetry
/// or fancier UI affordances can branch on the reason.
enum AskStreamGuardTrip { charCap, repetition }
