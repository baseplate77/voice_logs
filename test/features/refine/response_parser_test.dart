import 'package:flutter_test/flutter_test.dart';
import 'package:voxsynth/features/refine/response_parser.dart';

void main() {
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

  test('unknown entity types collapse to OTHER', () {
    final parsed = parseRecordLog(
      '{"cleaned_text":"X","entities":[{"text":"X","type":"BANANA"}]}',
    );
    expect(parsed!.mentions.first.type, 'OTHER');
  });

  test('returns null on malformed input', () {
    expect(parseRecordLog('not json at all'), isNull);
    expect(parseRecordLog('{broken'), isNull);
  });
}
