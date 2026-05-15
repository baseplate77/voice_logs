import 'package:flutter_test/flutter_test.dart';
import 'package:voxsynth/features/ask/ask_citation_parser.dart';

void main() {
  group('tokenizeAnswer', () {
    test('returns empty list for empty input', () {
      expect(tokenizeAnswer(''), isEmpty);
    });

    test('returns a single TextRun when no citations are present', () {
      final runs = tokenizeAnswer('plain answer with no citations');
      expect(runs, hasLength(1));
      expect(runs.first, isA<TextRun>());
      expect((runs.first as TextRun).text, 'plain answer with no citations');
    });

    test('splits text around log and memory citations', () {
      final runs = tokenizeAnswer('before [L1] middle [M2] tail');
      expect(runs, hasLength(5));
      expect((runs[0] as TextRun).text, 'before ');
      expect((runs[1] as CitationRun).citation.kind, CitationKind.log);
      expect((runs[1] as CitationRun).citation.index, 1);
      expect((runs[2] as TextRun).text, ' middle ');
      expect((runs[3] as CitationRun).citation.kind, CitationKind.memory);
      expect((runs[3] as CitationRun).citation.index, 2);
      expect((runs[4] as TextRun).text, ' tail');
    });

    test('handles back-to-back citations with no separating text', () {
      final runs = tokenizeAnswer('see [L1][L2] now');
      expect(runs.whereType<CitationRun>(), hasLength(2));
      expect((runs.whereType<CitationRun>().first).citation.index, 1);
      expect((runs.whereType<CitationRun>().last).citation.index, 2);
    });

    test('citations at start and end of text emit no empty text runs', () {
      final runs = tokenizeAnswer('[L1] only [M3]');
      // Expect: [L1], ' only ', [M3]
      expect(runs, hasLength(3));
      expect(runs.first, isA<CitationRun>());
      expect(runs.last, isA<CitationRun>());
    });

    test('drops zero-indexed citations rather than emitting them', () {
      final runs = tokenizeAnswer('weird [L0] case');
      expect(runs.whereType<CitationRun>(), isEmpty);
      // Whole string should remain as plain-text spans.
      expect(runs.map((r) => (r as TextRun).text).join(), 'weird [L0] case');
    });

    test('ignores malformed markers like [LX] or [L]', () {
      final runs = tokenizeAnswer('skip [LX] and [L] please');
      expect(runs.whereType<CitationRun>(), isEmpty);
    });
  });

  group('parseCitations', () {
    test('returns citations in source order with duplicates preserved', () {
      final cites = parseCitations('see [L1] then [L2] and again [L1]');
      expect(cites.map((c) => c.marker).toList(), ['[L1]', '[L2]', '[L1]']);
    });

    test('citation.hitOffset is zero-based', () {
      const cite = Citation(kind: CitationKind.log, index: 3);
      expect(cite.hitOffset, 2);
      expect(cite.marker, '[L3]');
    });
  });
}
