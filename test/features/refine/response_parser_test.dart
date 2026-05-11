import 'package:flutter_test/flutter_test.dart';
import 'package:voxsynth/features/refine/response_parser.dart';

void main() {
  test('parses cleanup-only response and repairs common STT leftovers', () {
    expect(
      parseCleanedTranscript(
        '{"cleaned_text":"doctor rao monday nine thirty terminal too air india one zero one"}',
      ),
      'Dr. Rao monday 9:30 Terminal 2 Air India 101',
    );
  });

  test('parses cleanup response with unescaped markdown line breaks', () {
    final parsed = parseCleanedTranscript('''
{
  "cleaned_text": "Tasks for tomorrow:
- Call Dr. Rao at 9:30.
- Send Project Atlas notes to Shivani."
}
''');

    expect(
      parsed,
      'Tasks for tomorrow:\n- Call Dr. Rao at 9:30.\n- Send Project Atlas notes to Shivani.',
    );
  });

  test('parses entity-only response and enforces cleaned-text substrings', () {
    final parsed = parseEntityMentions('''
{
  "entities": [
    {"text":"shivani","type":"person"},
    {"text":"Missing","type":"PLACE"}
  ]
}
''', cleanedText: 'I met Shivani at Cafe Coffee Day.');
    expect(parsed, isNotNull);
    expect(parsed, hasLength(1));
    expect(parsed!.first.text, 'Shivani');
    expect(parsed.first.type, 'PERSON');
  });

  test('trims action/preposition prefixes and filters generic phrases', () {
    final parsed = parseEntityMentions('''
{
  "entities": [
    {"text":"call Dr. Patel","type":"PERSON"},
    {"text":"from Delhi","type":"PLACE"},
    {"text":"blood test results","type":"TIME"},
    {"text":"book cake","type":"OTHER"}
  ]
}
''', cleanedText: 'Call Dr. Patel tomorrow before the flight from Delhi.');

    expect(parsed, isNotNull);
    expect(parsed!.map((m) => '${m.text}/${m.type}'), [
      'Dr. Patel/PERSON',
      'Delhi/PLACE',
      'tomorrow/TIME',
    ]);
  });

  test(
    'adds deterministic mentions for obvious dates, people, and projects',
    () {
      final parsed = parseEntityMentions(
        '{"entities":[]}',
        cleanedText: 'I met Dr. Rao for Project Atlas on Friday at 3 PM.',
      );

      expect(parsed, isNotNull);
      expect(
        parsed!.map((m) => '${m.text}/${m.type}'),
        containsAll([
          'Dr. Rao/PERSON',
          'Project Atlas/PROJECT',
          'Friday/TIME',
          '3 PM/TIME',
        ]),
      );
    },
  );

  test('parses a well-formed record_log response', () {
    final parsed = parseRecordLog('''
{
  "cleaned_text": "I met Shivani at the cafe.",
  "entities": [
    { "text": "Shivani", "type": "PERSON" }
  ]
}
''');
    expect(parsed, isNotNull);
    expect(parsed!.cleanedText, 'I met Shivani at the cafe.');
    expect(parsed.mentions, hasLength(1));
    expect(parsed.mentions.first.text, 'Shivani');
    expect(parsed.mentions.first.type, 'PERSON');
  });

  test('unwraps markdown-fenced responses', () {
    final parsed = parseRecordLog('''
Sure, here's the JSON:

```json
{"cleaned_text": "Hi.", "entities": []}
```
''');
    expect(parsed, isNotNull);
    expect(parsed!.cleanedText, 'Hi.');
    expect(parsed.mentions, isEmpty);
  });

  test('normalizes common SmolLM2 structured-output variants', () {
    final parsed = parseRecordLog('''
{
  "arguments": {
    "cleanedText": "I met Shivani at Cafe Coffee Day on Tuesday.",
    "entities": [
      { "name": "Shivani", "label": "people" },
      { "mention": "Cafe Coffee Day", "entity_type": "LOCATION" },
      { "text": "Tuesday", "type": "DATE" }
    ]
  }
}
''');
    expect(parsed, isNotNull);
    expect(parsed!.cleanedText, 'I met Shivani at Cafe Coffee Day on Tuesday.');
    expect(parsed.mentions.map((m) => m.type), ['PERSON', 'PLACE', 'TIME']);
  });

  test('parses grouped entity maps and de-duplicates mentions', () {
    final parsed = parseRecordLog('''
{
  "cleaned_text": "I met Shivani at Cafe Coffee Day.",
  "entities": {
    "people": ["Shivani", "Shivani"],
    "places": ["Cafe Coffee Day"]
  }
}
''');
    expect(parsed, isNotNull);
    expect(parsed!.mentions, hasLength(2));
    expect(parsed.mentions.map((m) => m.type), ['PERSON', 'PLACE']);
  });

  test('unknown entity types collapse to OTHER', () {
    final parsed = parseRecordLog(
      '{"cleaned_text":"X","entities":[{"text":"X","type":"BANANA"}]}',
    );
    expect(parsed!.mentions.first.type, 'OTHER');
  });

  test('caps entity mentions at 20', () {
    final entities = List<String>.generate(
      25,
      (i) => '{"text":"E$i","type":"OTHER"}',
    ).join(',');
    final parsed = parseRecordLog(
      '{"cleaned_text":"${List<String>.generate(25, (i) => 'E$i').join(' ')}","entities":[$entities]}',
    );
    expect(parsed!.mentions, hasLength(20));
  });

  test('returns null on malformed input', () {
    expect(parseRecordLog('not json at all'), isNull);
    expect(parseRecordLog('{broken'), isNull);
  });
}
