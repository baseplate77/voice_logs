import 'package:flutter_test/flutter_test.dart';
import 'package:voxsynth/llm/prompt_templates.dart';

void main() {
  group('PromptTemplate.render', () {
    test('substitutes every variable into the body', () {
      const t = PromptTemplate(
        name: 't',
        body: 'Hello {{name}}, welcome to {{place}}!',
        requiredVariables: <String>['name', 'place'],
      );
      expect(
        t.render(<String, String>{'name': 'Nayan', 'place': 'Pune'}),
        'Hello Nayan, welcome to Pune!',
      );
    });

    test('throws ArgumentError when a required variable is missing', () {
      const t = PromptTemplate(
        name: 'x',
        body: '{{a}} and {{b}}',
        requiredVariables: <String>['a', 'b'],
      );
      expect(
        () => t.render(<String, String>{'a': '1'}),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('replaces every occurrence of a placeholder', () {
      const t = PromptTemplate(
        name: 't',
        body: '{{x}}-{{x}}-{{x}}',
        requiredVariables: <String>['x'],
      );
      expect(t.render(<String, String>{'x': 'a'}), 'a-a-a');
    });

    test('leaves unused variables alone if caller passes extras', () {
      const t = PromptTemplate(
        name: 't',
        body: 'Hello {{name}}',
        requiredVariables: <String>['name'],
      );
      expect(
        t.render(<String, String>{'name': 'A', 'unused': 'X'}),
        'Hello A',
      );
    });
  });

  group('cleanupTemplate', () {
    test('renders with the transcript placeholder filled', () {
      final out = cleanupTemplate.render(<String, String>{
        'transcript': 'um hello world',
      });
      expect(out, contains('um hello world'));
      expect(out, contains('DO NOT paraphrase'));
      expect(out, isNot(contains('{{transcript}}')));
    });

    test('requires transcript', () {
      expect(cleanupTemplate.requiredVariables, <String>['transcript']);
    });
  });

  group('chunkBoundariesTemplate', () {
    test('renders with annotated_transcript filled', () {
      final out = chunkBoundariesTemplate.render(<String, String>{
        'annotated_transcript': '⟨0⟩ hello there',
      });
      expect(out, contains('⟨0⟩ hello there'));
      expect(out, contains('JSON array'));
      expect(out, isNot(contains('{{annotated_transcript}}')));
    });
  });

  group('entityExtractionTemplate', () {
    test('renders with transcript filled', () {
      final out = entityExtractionTemplate.render(<String, String>{
        'transcript': 'Alice and Bob worked on GlowUp.',
      });
      expect(out, contains('GlowUp'));
      expect(out, contains('JSON array'));
    });
  });

  group('entityExtractionRetryTemplate', () {
    test('emphasises JSON-only output', () {
      final out = entityExtractionRetryTemplate.render(<String, String>{
        'transcript': 't',
      });
      expect(out, contains('ONLY a JSON'));
      expect(out, contains('Empty'));
    });
  });

  group('tagsTemplate', () {
    test('asks for 1-4 tags', () {
      final out = tagsTemplate.render(<String, String>{'transcript': 't'});
      expect(out, contains('1–4'));
    });
  });
}
