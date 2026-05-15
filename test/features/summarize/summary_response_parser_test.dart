import 'package:flutter_test/flutter_test.dart';
import 'package:voxsynth/features/summarize/summary_response_parser.dart';

const _goodJson = '''
{
  "one_liner": "Discussed app launch planning with Raj.",
  "bullets": [
    "Investor deck needs updates.",
    "Launch target is next Friday.",
    "Raj will review pricing."
  ],
  "people_projects": ["Raj"],
  "decisions": ["Launch target set to next Friday."],
  "follow_ups": [
    "Update investor deck.",
    "Send Raj pricing draft."
  ]
}
''';

void main() {
  group('parseSummaryResponse', () {
    test('parses a clean JSON object', () {
      final parsed = parseSummaryResponse(_goodJson);
      expect(parsed, isNotNull);
      expect(parsed!.oneLiner, 'Discussed app launch planning with Raj.');
      expect(parsed.bullets, hasLength(3));
      expect(parsed.bullets.first, 'Investor deck needs updates.');
      expect(parsed.peopleProjects, ['Raj']);
      expect(parsed.decisions, ['Launch target set to next Friday.']);
      expect(parsed.followUps, [
        'Update investor deck.',
        'Send Raj pricing draft.',
      ]);
    });

    test('tolerates code-fenced output', () {
      const wrapped = '```json\n$_goodJson\n```';
      final parsed = parseSummaryResponse(wrapped);
      expect(parsed, isNotNull);
      expect(parsed!.bullets, hasLength(3));
    });

    test('tolerates trailing prose after the JSON', () {
      const wrapped = '$_goodJson\nLet me know if you need more detail.';
      final parsed = parseSummaryResponse(wrapped);
      expect(parsed, isNotNull);
      expect(parsed!.oneLiner, isNotEmpty);
    });

    test('unwraps a single wrapper key', () {
      const wrapped =
          '{"summary":{"one_liner":"A short note.","bullets":[],"people_projects":[],"decisions":[],"follow_ups":[]}}';
      final parsed = parseSummaryResponse(wrapped);
      expect(parsed, isNotNull);
      expect(parsed!.oneLiner, 'A short note.');
    });

    test('returns null when one_liner is missing', () {
      const missing =
          '{"bullets":["a","b","c"],"people_projects":[],"decisions":[],"follow_ups":[]}';
      expect(parseSummaryResponse(missing), isNull);
    });

    test('returns null on completely malformed output', () {
      expect(parseSummaryResponse('not json at all'), isNull);
    });

    test('caps bullets at three entries', () {
      const overflow =
          '{"one_liner":"x","bullets":["a","b","c","d","e"],"people_projects":[],"decisions":[],"follow_ups":[]}';
      final parsed = parseSummaryResponse(overflow);
      expect(parsed!.bullets, hasLength(3));
      expect(parsed.bullets, ['a', 'b', 'c']);
    });

    test('strips leading list markers from bullets', () {
      const marked =
          '{"one_liner":"x","bullets":["- one","* two","1) three"],"people_projects":[],"decisions":[],"follow_ups":[]}';
      final parsed = parseSummaryResponse(marked);
      expect(parsed!.bullets, ['one', 'two', 'three']);
    });

    test('dedupes list items case-insensitively', () {
      const dupes =
          '{"one_liner":"x","bullets":["Same","same","SAME"],"people_projects":["Raj","raj"],"decisions":[],"follow_ups":[]}';
      final parsed = parseSummaryResponse(dupes);
      expect(parsed!.bullets, ['Same']);
      expect(parsed.peopleProjects, ['Raj']);
    });

    test('accepts comma-separated string lists from smaller models', () {
      const csv =
          '{"one_liner":"x","bullets":["a","b"],"people_projects":"Raj, Shivani","decisions":[],"follow_ups":[]}';
      final parsed = parseSummaryResponse(csv);
      expect(parsed!.peopleProjects, ['Raj', 'Shivani']);
    });

    test('extracts text from {"text": "..."} objects in lists', () {
      const objectList =
          '{"one_liner":"x","bullets":[{"text":"point one"}],"people_projects":[],"decisions":[],"follow_ups":[]}';
      final parsed = parseSummaryResponse(objectList);
      expect(parsed!.bullets, ['point one']);
    });
  });
}
