import 'models/cleaned_transcript.dart';

/// Minimum words per chunk — shorter and we force a fallback.
const int kChunkMinWords = 50;

/// Maximum words per chunk — longer and we force a fallback.
const int kChunkMaxWords = 500;

/// Target size for fixed-width fallback chunks.
const int kChunkFallbackWords = 200;

/// A boundary proposal from the LLM (or wherever). [TopicChunker] validates
/// a list of these and either returns proper [TopicChunk]s or falls back
/// to fixed-width chunking.
final class ProposedBoundary {
  const ProposedBoundary({
    required this.start,
    required this.end,
    required this.topic,
  });

  final int start;
  final int end;
  final String topic;
}

/// Reason the chunker fell back to fixed-width chunks. Pure data —
/// [CleanupPipeline] surfaces this through the `AppLogger`.
enum ChunkingFallbackReason {
  none,
  empty,
  outOfRange,
  overlap,
  notOrdered,
  chunkTooShort,
  chunkTooLong,
  doesNotCoverText,
}

/// Result of chunking, including why we fell back if we did.
final class ChunkingResult {
  const ChunkingResult({required this.chunks, required this.fallbackReason});

  final List<TopicChunk> chunks;
  final ChunkingFallbackReason fallbackReason;

  bool get isFallback => fallbackReason != ChunkingFallbackReason.none;
}

/// Pure state-free chunker. Given cleaned text and optional
/// LLM-proposed boundaries, returns a [ChunkingResult].
class TopicChunker {
  const TopicChunker();

  /// Produce chunks for [text]. If [proposed] validates cleanly, use it;
  /// otherwise split [text] into [kChunkFallbackWords]-word chunks at
  /// word boundaries and tag [ChunkingFallbackReason].
  ChunkingResult chunk(String text, List<ProposedBoundary>? proposed) {
    if (text.isEmpty) {
      return const ChunkingResult(
        chunks: <TopicChunk>[],
        fallbackReason: ChunkingFallbackReason.none,
      );
    }

    final reason = _validate(text, proposed);
    if (reason == ChunkingFallbackReason.none) {
      final chunks = <TopicChunk>[];
      for (final b in proposed!) {
        chunks.add(
          TopicChunk(
            text: text.substring(b.start, b.end),
            startChar: b.start,
            endChar: b.end,
            topicHint: b.topic,
          ),
        );
      }
      return ChunkingResult(
        chunks: chunks,
        fallbackReason: ChunkingFallbackReason.none,
      );
    }

    return ChunkingResult(
      chunks: _fixedWidthChunks(text),
      fallbackReason: reason,
    );
  }

  /// Returns [ChunkingFallbackReason.none] if [proposed] is valid; the
  /// reason otherwise. Shape rules:
  ///   1. Non-null, non-empty.
  ///   2. Each `[start, end)` lies within [0, text.length].
  ///   3. Boundaries are ordered and non-overlapping (gaps allowed if
  ///      they only contain whitespace — LLMs typically emit chunk
  ///      boundaries that skip the whitespace between sentences).
  ///   4. Every chunk is [kChunkMinWords, kChunkMaxWords] words.
  ///   5. Anything the boundaries don't cover must be pure whitespace.
  ChunkingFallbackReason _validate(
    String text,
    List<ProposedBoundary>? proposed,
  ) {
    if (proposed == null || proposed.isEmpty) {
      return ChunkingFallbackReason.empty;
    }
    final len = text.length;
    var prevEnd = 0;
    for (final b in proposed) {
      if (b.start < 0 || b.end > len || b.start >= b.end) {
        return ChunkingFallbackReason.outOfRange;
      }
      if (b.start < prevEnd) return ChunkingFallbackReason.overlap;
      // Gap between prevEnd and b.start must be whitespace-only.
      if (b.start > prevEnd &&
          !_isWhitespaceOnly(text.substring(prevEnd, b.start))) {
        return ChunkingFallbackReason.doesNotCoverText;
      }
      final words = _wordCount(text.substring(b.start, b.end));
      if (words < kChunkMinWords) {
        return ChunkingFallbackReason.chunkTooShort;
      }
      if (words > kChunkMaxWords) {
        return ChunkingFallbackReason.chunkTooLong;
      }
      prevEnd = b.end;
    }
    // Tail: anything left must be whitespace-only too.
    if (prevEnd < len && !_isWhitespaceOnly(text.substring(prevEnd, len))) {
      return ChunkingFallbackReason.doesNotCoverText;
    }
    return ChunkingFallbackReason.none;
  }

  static bool _isWhitespaceOnly(String s) {
    for (var i = 0; i < s.length; i++) {
      if (!_isWs(s.codeUnitAt(i))) return false;
    }
    return true;
  }

  /// Fallback: split [text] into ~[kChunkFallbackWords]-word chunks,
  /// cutting at whitespace boundaries only (never mid-word).
  List<TopicChunk> _fixedWidthChunks(String text) {
    final chunks = <TopicChunk>[];
    final tokens = _tokenSpans(text);
    if (tokens.isEmpty) return chunks;

    var i = 0;
    while (i < tokens.length) {
      final end = (i + kChunkFallbackWords).clamp(0, tokens.length).toInt();
      final startChar = tokens[i].start;
      final endChar = tokens[end - 1].end;
      chunks.add(
        TopicChunk(
          text: text.substring(startChar, endChar),
          startChar: startChar,
          endChar: endChar,
          topicHint: '(fixed-width fallback)',
        ),
      );
      i = end;
    }
    return chunks;
  }

  static int _wordCount(String s) {
    if (s.isEmpty) return 0;
    return s.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length;
  }

  /// Returns `[start, end)` spans for every whitespace-delimited token in
  /// [text], in order.
  static List<_TokenSpan> _tokenSpans(String text) {
    final out = <_TokenSpan>[];
    var i = 0;
    while (i < text.length) {
      // Skip leading whitespace.
      while (i < text.length && _isWs(text.codeUnitAt(i))) {
        i++;
      }
      if (i >= text.length) break;
      final start = i;
      while (i < text.length && !_isWs(text.codeUnitAt(i))) {
        i++;
      }
      out.add(_TokenSpan(start: start, end: i));
    }
    return out;
  }

  static bool _isWs(int cu) => cu == 0x20 || cu == 0x09 || cu == 0x0a || cu == 0x0d;
}

class _TokenSpan {
  const _TokenSpan({required this.start, required this.end});
  final int start;
  final int end;
}
