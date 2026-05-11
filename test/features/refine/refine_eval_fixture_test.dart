import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _validEntityTypes = {
  'PERSON',
  'PLACE',
  'PROJECT',
  'DURATION',
  'TIME',
  'NUMBER',
  'OTHER',
};

void main() {
  test('refine eval fixture has valid expected outputs', () async {
    final file = File('assets/eval/refine_eval_cases.json');
    final decoded = jsonDecode(await file.readAsString());
    expect(decoded, isA<List<Object?>>());

    final cases = decoded as List<Object?>;
    expect(cases, hasLength(50));

    final ids = <String>{};
    for (final item in cases) {
      expect(item, isA<Map<String, Object?>>());
      final row = item! as Map<String, Object?>;

      final id = _requiredString(row, 'id');
      expect(ids.add(id), isTrue, reason: 'duplicate id $id');

      final rawTranscript = _requiredString(row, 'rawTranscript');
      final cleanedText = _requiredString(row, 'expectedCleanedText');
      expect(rawTranscript.trim(), isNotEmpty, reason: id);
      expect(cleanedText.trim(), isNotEmpty, reason: id);

      final entities = _requiredList(row, 'expectedEntities');
      for (final entity in entities) {
        expect(entity, isA<Map<String, Object?>>(), reason: id);
        final entityMap = entity! as Map<String, Object?>;
        final text = _requiredString(entityMap, 'text');
        final type = _requiredString(entityMap, 'type');
        expect(_validEntityTypes, contains(type), reason: '$id entity $text');
        expect(
          cleanedText.contains(text),
          isTrue,
          reason: '$id entity "$text" must be an exact cleaned-text substring',
        );
      }

      final reminders = _requiredList(row, 'expectedReminders');
      for (final reminder in reminders) {
        expect(reminder, isA<String>(), reason: id);
        final text = reminder! as String;
        expect(text.trim(), isNotEmpty, reason: id);
        expect(
          cleanedText.contains(text),
          isTrue,
          reason:
              '$id reminder "$text" must be an exact cleaned-text substring',
        );
      }

      expect(_requiredList(row, 'phenomena'), isNotEmpty, reason: id);
    }
  });
}

String _requiredString(Map<String, Object?> row, String key) {
  final value = row[key];
  expect(value, isA<String>(), reason: 'missing string $key');
  return value! as String;
}

List<Object?> _requiredList(Map<String, Object?> row, String key) {
  final value = row[key];
  expect(value, isA<List<Object?>>(), reason: 'missing list $key');
  return value! as List<Object?>;
}
