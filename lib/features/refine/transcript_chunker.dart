/// Utilities for splitting long transcripts into model-safe chunks.
library;

/// Conservative raw text chunk size for Gemma 3 1B with a 1024-token session.
///
/// Cleanup needs room for prompt instructions, the input chunk, and a similarly
/// sized output chunk. Keeping chunks small avoids context overflow and reduces
/// the chance that the model summarizes instead of editing.
const int kRefineChunkMaxChars = 900;

const int _defaultMinBreakChars = 360;

/// A chunk of transcript text with offsets into the original transcript.
class TranscriptChunk {
  const TranscriptChunk({
    required this.text,
    required this.sourceStart,
    required this.sourceEnd,
  });

  /// Exact text slice from the original transcript.
  final String text;

  /// Inclusive start offset in the original transcript.
  final int sourceStart;

  /// Exclusive end offset in the original transcript.
  final int sourceEnd;
}

/// Split [transcript] into exact, ordered slices for model refinement.
///
/// The splitter prefers sentence boundaries, then newlines, then whitespace.
/// It only hard-splits inside a word when a single word is longer than
/// [maxChars]. Concatenating all returned chunk texts always reconstructs the
/// original transcript exactly.
List<TranscriptChunk> splitTranscriptForRefine(
  String transcript, {
  int maxChars = kRefineChunkMaxChars,
}) {
  if (maxChars < 64) {
    throw ArgumentError.value(maxChars, 'maxChars', 'Must be at least 64.');
  }
  if (transcript.isEmpty) return const [];
  if (transcript.length <= maxChars) {
    return [
      TranscriptChunk(
        text: transcript,
        sourceStart: 0,
        sourceEnd: transcript.length,
      ),
    ];
  }

  final chunks = <TranscriptChunk>[];
  var start = 0;
  while (start < transcript.length) {
    final hardEnd = (start + maxChars).clamp(0, transcript.length);
    if (hardEnd == transcript.length) {
      chunks.add(
        TranscriptChunk(
          text: transcript.substring(start),
          sourceStart: start,
          sourceEnd: transcript.length,
        ),
      );
      break;
    }

    final end = _bestBreak(transcript, start, hardEnd) ?? hardEnd;
    final safeEnd = end <= start ? hardEnd : end;
    chunks.add(
      TranscriptChunk(
        text: transcript.substring(start, safeEnd),
        sourceStart: start,
        sourceEnd: safeEnd,
      ),
    );
    start = safeEnd;
  }
  return chunks;
}

int? _bestBreak(String text, int start, int hardEnd) {
  final window = hardEnd - start;
  final minOffset = window < _defaultMinBreakChars
      ? (window * 0.45).floor()
      : _defaultMinBreakChars;
  final minBreak = (start + minOffset).clamp(start + 1, hardEnd);

  for (var i = hardEnd - 1; i >= minBreak; i--) {
    if (_isSentenceBreak(text, i)) {
      return _includeTrailingWhitespace(text, i + 1, hardEnd);
    }
  }

  for (var i = hardEnd - 1; i >= minBreak; i--) {
    if (text.codeUnitAt(i) == 10) return i + 1;
  }

  for (var i = hardEnd - 1; i >= minBreak; i--) {
    if (_isWhitespace(text.codeUnitAt(i))) return i + 1;
  }

  for (var i = hardEnd - 1; i > start; i--) {
    if (_isWhitespace(text.codeUnitAt(i))) return i + 1;
  }

  return null;
}

bool _isSentenceBreak(String text, int index) {
  final unit = text.codeUnitAt(index);
  if (unit != 46 && unit != 33 && unit != 63) return false;
  if (index > 0 && _isDigit(text.codeUnitAt(index - 1))) return false;
  if (index + 1 >= text.length) return true;
  return _isWhitespace(text.codeUnitAt(index + 1));
}

int _includeTrailingWhitespace(String text, int index, int hardEnd) {
  var end = index;
  while (end < hardEnd && _isWhitespace(text.codeUnitAt(end))) {
    end++;
  }
  return end;
}

bool _isWhitespace(int codeUnit) {
  return codeUnit == 32 || codeUnit == 9 || codeUnit == 10 || codeUnit == 13;
}

bool _isDigit(int codeUnit) => codeUnit >= 48 && codeUnit <= 57;
