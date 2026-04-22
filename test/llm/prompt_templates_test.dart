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

    test('instructs the model to apply in-speech self-corrections', () {
      final out = cleanupTemplate.render(<String, String>{'transcript': 't'});
      expect(out, contains('SELF-CORRECTIONS'));
      expect(out, contains('the same specific fact'));
      expect(out, contains('never justifies removing an unrelated'));
    });

    test('instructs the model to use Markdown lists for enumerations', () {
      final out = cleanupTemplate.render(<String, String>{'transcript': 't'});
      expect(out, contains('Markdown bullet list'));
      expect(out, contains('Markdown numbered list'));
    });

    test('forbids translation and invented content', () {
      final out = cleanupTemplate.render(<String, String>{'transcript': 't'});
      expect(out, contains('DO NOT translate'));
      expect(out, contains('DO NOT invent content'));
    });

    test('calls out every load-bearing entity category explicitly', () {
      final out = cleanupTemplate.render(<String, String>{'transcript': 't'});
      expect(out, contains('PRESERVE VERBATIM'));
      for (final category in const <String>[
        'People',
        'Places',
        'Organisations',
        'Dates',
        'Times',
        'Deadlines',
        'Numbers',
        'Subjects',
        'Decisions',
      ]) {
        expect(
          out,
          contains(category),
          reason: 'cleanup prompt must explicitly name "$category" '
              'so the model does not drop values in that category',
        );
      }
    });

    test('instructs the model to canonicalise number formats', () {
      final out = cleanupTemplate.render(<String, String>{'transcript': 't'});
      expect(out, contains('NUMBERS & FORMATTING'));
      // Each numeric category the user flagged as currently broken.
      for (final category in const <String>[
        'Years',
        'Dates',
        'Times',
        'Durations',
        'Ages',
        'Money',
        'Percentages',
      ]) {
        expect(
          out,
          contains(category),
          reason: 'NUMBERS & FORMATTING must explicitly cover "$category"',
        );
      }
    });

    test('specifies currency handling with symbol + ISO fallback', () {
      final out = cleanupTemplate.render(<String, String>{'transcript': 't'});
      // Rupees, dollars, euros, pounds all need canonical mappings.
      expect(out, contains('Rupees'));
      expect(out, contains('INR'));
      expect(out, contains('USD'));
      expect(out, contains('EUR'));
      expect(out, contains('GBP'));
      // Indian numbering must not be flattened to Western grouping.
      expect(out, contains('lakh'));
      expect(out, contains('crore'));
    });

    test('forbids changing the value of a number', () {
      final out = cleanupTemplate.render(<String, String>{'transcript': 't'});
      expect(out, contains('DO NOT change the value or meaning of any number'));
    });

    test('demonstrates canonical number forms inline', () {
      // The worked example was dropped to fit the 4k-token context
      // window, but the number-normalisation conversions must still
      // appear as micro-examples so the model has anchors to copy.
      final out = cleanupTemplate.render(<String, String>{'transcript': 't'});
      expect(out, contains('"twenty twenty six" → "2026"'));
      expect(out, contains('"4pm" → "4:00 PM"'));
      expect(out, contains('₹1,50,000'));
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
