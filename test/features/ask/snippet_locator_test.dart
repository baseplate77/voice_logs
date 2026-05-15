import 'package:flutter_test/flutter_test.dart';
import 'package:voxsynth/core/db/repositories/transcript_segment_repository.dart';
import 'package:voxsynth/features/ask/snippet_locator.dart';

TranscriptSegmentView _seg({
  required String id,
  required int startMs,
  required int endMs,
  required String text,
}) {
  return TranscriptSegmentView(
    id: id,
    logId: 'log-1',
    startMs: startMs,
    endMs: endMs,
    text: text,
    words: const [],
  );
}

void main() {
  group('locateSnippet', () {
    test('returns null when segments are empty', () {
      expect(locateSnippet(snippet: 'anything', segments: const []), isNull);
    });

    test('returns null when snippet is blank', () {
      final segs = [_seg(id: 'a', startMs: 0, endMs: 1000, text: 'hello')];
      expect(locateSnippet(snippet: '   ', segments: segs), isNull);
    });

    test('matches a snippet that appears verbatim in a segment', () {
      final segs = [
        _seg(id: 'a', startMs: 0, endMs: 1000, text: 'we met shivani today'),
        _seg(
          id: 'b',
          startMs: 1000,
          endMs: 2000,
          text: 'and grabbed coffee after',
        ),
      ];
      final loc = locateSnippet(snippet: 'met Shivani today', segments: segs);
      expect(loc, isNotNull);
      expect(loc!.startMs, 0);
      expect(loc.endMs, 1000);
    });

    test('match is case-insensitive and whitespace-tolerant', () {
      final segs = [
        _seg(id: 'a', startMs: 500, endMs: 1500, text: 'the QUARTERLY review'),
      ];
      final loc = locateSnippet(
        snippet: '   the   quarterly   review  ',
        segments: segs,
      );
      expect(loc?.startMs, 500);
    });

    test('falls back to a leading 24-char window when full match fails', () {
      final segs = [
        _seg(
          id: 'a',
          startMs: 2000,
          endMs: 4000,
          text: 'i was telling shivani about the migration plan',
        ),
      ];
      // Refined snippet rephrases the back half but keeps the lead identical.
      final loc = locateSnippet(
        snippet: 'i was telling shivani about a different topic entirely',
        segments: segs,
      );
      expect(loc?.startMs, 2000);
    });

    test('returns null when nothing matches even the leading window', () {
      final segs = [
        _seg(id: 'a', startMs: 0, endMs: 1000, text: 'this is unrelated text'),
      ];
      final loc = locateSnippet(
        snippet: 'completely different phrase that does not match',
        segments: segs,
      );
      expect(loc, isNull);
    });
  });
}
