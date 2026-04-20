import 'package:meta/meta.dart';

import '../../retrieve/models/ranked_chunk.dart';

/// Whether a [Citation] points at a transcript chunk or a distilled
/// memory (Phase 8). The UI uses this to pick the right glyph + click
/// target.
enum CitationSourceKind { chunk, memory }

/// One citation Gemma put into its answer, resolved back to the source
/// it cites and the character span where it appears.
///
/// `spanStart`/`spanEnd` are offsets into `SynthesisComplete.answer`;
/// they include the marker itself so UIs can underline the citation or
/// strip it depending on the rendering mode.
///
/// Sources are either transcript chunks (`[Cn]` tags, [chunkId] set) or
/// memories (`[Mn]` tags, [memoryId] set). Exactly one of the two ids
/// is non-null; [sourceKind] discriminates. Chunk citations constructed
/// without naming [sourceKind] default to [CitationSourceKind.chunk],
/// preserving the pre-Phase-8 behaviour.
@immutable
final class Citation {
  const Citation({
    required this.tag,
    required this.spanStart,
    required this.spanEnd,
    this.chunkId = 0,
    this.memoryId,
    this.sourceKind = CitationSourceKind.chunk,
  })  : assert(spanEnd > spanStart, 'spanEnd must be > spanStart'),
        assert(spanStart >= 0, 'spanStart must be >= 0');

  /// The tag as it appeared in the answer (without brackets), e.g.
  /// `C1`, `C12`, `M3`.
  final String tag;

  /// Chunk the citation resolves to when [sourceKind] is
  /// [CitationSourceKind.chunk]. Zero when irrelevant.
  final int chunkId;

  /// Memory id the citation resolves to when [sourceKind] is
  /// [CitationSourceKind.memory]. Null when irrelevant.
  final String? memoryId;

  final CitationSourceKind sourceKind;

  /// `[start, end)` offsets into the full answer text. The slice
  /// `answer.substring(spanStart, spanEnd)` yields `[tag]` literally.
  final int spanStart;
  final int spanEnd;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Citation &&
          other.tag == tag &&
          other.chunkId == chunkId &&
          other.memoryId == memoryId &&
          other.sourceKind == sourceKind &&
          other.spanStart == spanStart &&
          other.spanEnd == spanEnd);

  @override
  int get hashCode => Object.hash(
        tag,
        chunkId,
        memoryId,
        sourceKind,
        spanStart,
        spanEnd,
      );

  @override
  String toString() {
    final target = sourceKind == CitationSourceKind.memory
        ? 'memory ${memoryId ?? '?'}'
        : 'chunk #$chunkId';
    return 'Citation($tag → $target @ [$spanStart..$spanEnd])';
  }
}

/// Event in the streaming answer pipeline. The synthesizer emits
/// these in order; UI consumers wire each to a specific surface.
sealed class SynthesisEvent {
  const SynthesisEvent();
}

/// Fired once, at the start of a retrieve call. UIs can show a
/// "thinking" spinner.
final class RetrievalStarted extends SynthesisEvent {
  const RetrievalStarted();
}

/// Fired once retrieval finishes. Carries the chunks that will be fed
/// to the LLM prompt — useful for surfacing source previews while the
/// answer is still generating.
final class RetrievalComplete extends SynthesisEvent {
  const RetrievalComplete({required this.chunks});
  final List<RankedChunk> chunks;
}

/// Per-token streaming event. Multiple arrive per answer.
final class TokenGenerated extends SynthesisEvent {
  const TokenGenerated({required this.token});
  final String token;
}

/// Terminal event — carries the full assembled answer + resolved
/// citations. Listeners should close their subscriptions after this.
final class SynthesisComplete extends SynthesisEvent {
  const SynthesisComplete({
    required this.answer,
    required this.citations,
  });

  /// The full answer text, exactly as built up by concatenating every
  /// [TokenGenerated].
  final String answer;

  /// Resolved citations in their textual order (first `[C1]` in the
  /// answer appears first in the list).
  final List<Citation> citations;
}

/// Terminal event when synthesis fails. Streams complete after this.
final class SynthesisFailed extends SynthesisEvent {
  const SynthesisFailed({required this.message, this.cause});
  final String message;
  final Object? cause;
}
