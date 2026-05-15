import 'package:flutter_test/flutter_test.dart';
import 'package:voxsynth/features/digest/digest_response_parser.dart';

void main() {
  group('parseDailyDigestResponse', () {
    test('parses a well-formed daily digest', () {
      const response = '''
{
  "one_liner": "A focused day shipping the new digest feature.",
  "what_happened": [
    "Designed the Phase 11 digest pipeline.",
    "Implemented the runner and prompts.",
    "Wired up a debug-screen test button."
  ],
  "people_mentioned": ["Raj", "Shivani"],
  "tasks_created": ["Write digest tests.", "Wire up the debug button."],
  "decisions": ["On-demand only for v1."],
  "mood_theme": "focused on shipping"
}
''';
      final parsed = parseDailyDigestResponse(response);
      expect(parsed, isNotNull);
      expect(parsed!.oneLiner, contains('focused day'));
      expect(parsed.bullets, hasLength(3));
      expect(parsed.topics, containsAll(<String>['Raj', 'Shivani']));
      expect(parsed.actions, hasLength(2));
      expect(parsed.decisions, ['On-demand only for v1.']);
      expect(parsed.mood, 'focused on shipping');
    });

    test('tolerates code-fence wrapping and stray prose', () {
      const response = '''
Sure, here is the digest you asked for:

```json
{"one_liner":"Quiet morning, productive afternoon.","what_happened":["Walked the dog.","Cleared the inbox."],"people_mentioned":[],"tasks_created":[],"decisions":[],"mood_theme":""}
```
''';
      final parsed = parseDailyDigestResponse(response);
      expect(parsed, isNotNull);
      expect(parsed!.bullets, hasLength(2));
      expect(parsed.mood, isNull);
    });

    test('returns null when JSON is unrecoverable', () {
      final parsed = parseDailyDigestResponse('Not JSON at all, sorry.');
      expect(parsed, isNull);
    });

    test('returns null when the one-liner is missing', () {
      const response = '{"what_happened":["a","b"],"mood_theme":"calm"}';
      expect(parseDailyDigestResponse(response), isNull);
    });

    test('strips leading list markers and trims long bullets', () {
      final padded = 'x' * 300;
      final response =
          '{"one_liner":"Test.","what_happened":["- first thing","* second thing","$padded"]}';
      final parsed = parseDailyDigestResponse(response);
      expect(parsed, isNotNull);
      expect(parsed!.bullets[0], 'first thing');
      expect(parsed.bullets[1], 'second thing');
      expect(parsed.bullets[2].length, lessThan(padded.length));
    });

    test('caps daily bullets at five entries', () {
      const response =
          '{"one_liner":"Test.","what_happened":["a","b","c","d","e","f","g"]}';
      final parsed = parseDailyDigestResponse(response);
      expect(parsed, isNotNull);
      expect(parsed!.bullets, hasLength(5));
    });

    test('unwraps a nested digest wrapper key', () {
      const response =
          '{"digest":{"one_liner":"Wrapped.","what_happened":["one"],"people_mentioned":["A"]}}';
      final parsed = parseDailyDigestResponse(response);
      expect(parsed, isNotNull);
      expect(parsed!.oneLiner, 'Wrapped.');
      expect(parsed.topics, ['A']);
    });
  });

  group('parseWeeklyDigestResponse', () {
    test('parses a well-formed weekly digest', () {
      const response = '''
{
  "one_liner": "Steady progress on shipping and onboarding.",
  "main_themes": ["Shipping Phase 11", "Onboarding polish"],
  "project_progress": ["Digest pipeline scaffolded.", "Onboarding bug fixed."],
  "repeated_concerns": ["Worried about Gemma JSON drift."],
  "unfinished_tasks": ["Wire up summary panel.", "Write integration test."]
}
''';
      final parsed = parseWeeklyDigestResponse(response);
      expect(parsed, isNotNull);
      expect(parsed!.bullets, hasLength(2));
      expect(parsed.topics, hasLength(2));
      expect(parsed.decisions.single, contains('Gemma JSON drift'));
      expect(parsed.actions, hasLength(2));
      // Weekly digests never carry a mood line.
      expect(parsed.mood, isNull);
    });

    test('returns null on a malformed weekly response', () {
      expect(parseWeeklyDigestResponse('completely garbled'), isNull);
    });
  });
}
