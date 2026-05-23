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

  test('parses cleanup response with generated title (legacy shape)', () {
    final parsed = parseCleanupTranscript(
      '{"cleaned_text":"Today I talked to Raj about the app launch.",'
      '"title":"Raj call about app launch."}',
    );

    expect(parsed, isNotNull);
    expect(parsed!.cleanedText, 'Today I talked to Raj about the app launch.');
    expect(parsed.title, 'Raj call about app launch');
  });

  group('parseTitleResponse', () {
    test('extracts the title key from a well-formed JSON object', () {
      expect(
        parseTitleResponse(
          '{"title":"Shivani meeting on Project Atlas"}',
        ).title,
        'Shivani meeting on Project Atlas',
      );
    });

    test('strips trailing punctuation and wrapping quotes', () {
      expect(
        parseTitleResponse(
          '{"title":" "Send revised deck to Shivani." "}',
        ).title,
        'Send revised deck to Shivani',
      );
    });

    test('returns null when there is no JSON envelope at all', () {
      expect(parseTitleResponse('Dr. Rao dentist appointment').title, isNull);
    });

    test('handles a malformed JSON via loose extraction', () {
      expect(
        parseTitleResponse('{"title":"Pick up Mom from airport" ,').title,
        'Pick up Mom from airport',
      );
    });

    test('returns null for whitespace-only responses', () {
      expect(parseTitleResponse('   \n  ').title, isNull);
    });

    test('returns null when the title key resolves to an empty string', () {
      expect(parseTitleResponse('{"title":""}').title, isNull);
    });

    test('parses a well-formed suggestions response', () {
      final parsed = parseSuggestionsResponse(
        '{"suggestions":['
        '{"chip":"Coffee with Shivani","question":"What did I discuss with Shivani over coffee?"},'
        '{"chip":"Project Atlas","question":"What is the latest on Project Atlas?"}'
        ']}',
      );
      expect(parsed, isNotNull);
      expect(parsed, hasLength(2));
      expect(parsed!.first.chipText, 'Coffee with Shivani');
      expect(
        parsed.first.question,
        'What did I discuss with Shivani over coffee?',
      );
    });

    test('suggestions dedupe chips by case-insensitive label', () {
      final parsed = parseSuggestionsResponse(
        '{"suggestions":['
        '{"chip":"Coffee","question":"What did I say about coffee?"},'
        '{"chip":"coffee","question":"When did I have coffee last?"},'
        '{"chip":"Atlas","question":"What is the latest on Atlas?"}'
        ']}',
      );
      expect(parsed, isNotNull);
      expect(parsed!.map((s) => s.chipText), ['Coffee', 'Atlas']);
    });

    test('suggestions cap at four entries', () {
      final raw = List.generate(
        7,
        (i) => '{"chip":"Topic $i","question":"What is question $i about?"}',
      ).join(',');
      final parsed = parseSuggestionsResponse('{"suggestions":[$raw]}');
      expect(parsed, isNotNull);
      expect(parsed, hasLength(4));
    });

    test('suggestions drop generic single-word chips', () {
      final parsed = parseSuggestionsResponse(
        '{"suggestions":['
        '{"chip":"Summary","question":"What is this about?"},'
        '{"chip":"Coffee with Shivani","question":"What did I discuss with Shivani?"}'
        ']}',
      );
      expect(parsed, isNotNull);
      expect(parsed!.map((s) => s.chipText), ['Coffee with Shivani']);
    });

    test('suggestions append a question mark if missing', () {
      final parsed = parseSuggestionsResponse(
        '{"suggestions":['
        '{"chip":"Coffee with Shivani","question":"What did I discuss with Shivani over coffee"}'
        ']}',
      );
      expect(parsed!.first.question.endsWith('?'), isTrue);
    });

    test('suggestions return null when JSON is malformed', () {
      expect(parseSuggestionsResponse('not json at all'), isNull);
      expect(parseSuggestionsResponse('{"suggestions":[{"chip":'), isNull);
    });

    test('suggestions return empty list when array is empty', () {
      final parsed = parseSuggestionsResponse('{"suggestions":[]}');
      expect(parsed, isNotNull);
      expect(parsed, isEmpty);
    });

    test('caps overlong titles to about 12 words', () {
      const long =
          'this is a deliberately overlong title that should be truncated before twelve words appear';
      final result = parseTitleResponse('{"title":"$long"}').title;
      expect(result, isNotNull);
      final wordCount = RegExp(r'[A-Za-z0-9]+').allMatches(result!).length;
      expect(wordCount, lessThanOrEqualTo(12));
    });

    test(
      'extracts and normalizes flower type from well-formed JSON and synonym/vibe fallback',
      () {
        // 1. Exact match
        expect(
          parseTitleResponse(
            '{"title":"Sunny day", "flower_type":"sunflower"}',
          ).flowerType,
          'sunflower',
        );
        // 2. Vibe fallback - 'calm' maps to lavender
        expect(
          parseTitleResponse(
            '{"title":"Reflections", "vibe":"calm"}',
          ).flowerType,
          'lavender',
        );
        // 3. Synonym fallback - 'love' maps to rose
        expect(
          parseTitleResponse(
            '{"title":"Family time", "flower":"love"}',
          ).flowerType,
          'rose',
        );
        // 4. Default to sakura if unknown vibe
        expect(
          parseTitleResponse(
            '{"title":"Random log", "type":"unknown_vibe"}',
          ).flowerType,
          'sakura',
        );
        // 5. Default/Null if absent
        expect(
          parseTitleResponse('{"title":"No flower type info"}').flowerType,
          isNull,
        );
      },
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
