import 'package:flutter_test/flutter_test.dart';
import 'package:voxsynth/features/refine/entity_summary_prompt.dart';

void main() {
  group('entitySummaryFullPrompt', () {
    test('renders titles and snippets into the prompt body', () {
      const input = EntitySummaryPromptInput(
        displayName: 'Shivani',
        type: 'PERSON',
        mentionCount: 4,
        recentLogTitles: ['Coffee with Shivani', 'Atlas standup notes'],
        recentLogSnippets: ['Met Shivani at Cafe Coffee Day.'],
      );
      final prompt = entitySummaryFullPrompt(input);
      expect(prompt, contains('"Shivani"'));
      expect(prompt, contains('person'));
      expect(prompt, contains('- Coffee with Shivani'));
      expect(prompt, contains('> Met Shivani at Cafe Coffee Day.'));
      expect(prompt, contains('"facts"'));
      expect(prompt, contains('"key_facts"'));
      expect(prompt, contains('"recent_themes"'));
    });

    test('uses project lens and exposes status hint for PROJECT entities', () {
      const input = EntitySummaryPromptInput(
        displayName: 'Project Atlas',
        type: 'PROJECT',
        mentionCount: 2,
        recentLogTitles: ['Atlas launch'],
        recentLogSnippets: [],
      );
      final prompt = entitySummaryFullPrompt(input);
      expect(prompt, contains('background dossier for a project'));
      expect(prompt, contains('"status"'));
      expect(prompt, isNot(contains('"relationship"')));
    });

    test('exposes relationship hint for PERSON entities', () {
      const input = EntitySummaryPromptInput(
        displayName: 'Shivani',
        type: 'PERSON',
        mentionCount: 1,
        recentLogTitles: [],
        recentLogSnippets: [],
      );
      final prompt = entitySummaryFullPrompt(input);
      expect(prompt, contains('"relationship"'));
      expect(prompt, isNot(contains('"status"')));
    });

    test('uses object lens for OBJECT entities', () {
      const input = EntitySummaryPromptInput(
        displayName: 'Hario V60',
        type: 'OBJECT',
        mentionCount: 1,
        recentLogTitles: [],
        recentLogSnippets: [],
      );
      final prompt = entitySummaryFullPrompt(input);
      expect(prompt, contains('background dossier for a object'));
    });
  });

  group('entitySummaryIncrementalPrompt', () {
    test('embeds existing facts JSON and the new snippets', () {
      const input = EntitySummaryPromptInput(
        displayName: 'Shivani',
        type: 'PERSON',
        mentionCount: 5,
        recentLogTitles: ['New mention log'],
        recentLogSnippets: ['Shivani moved to the Mumbai office.'],
      );
      const facts = EntityStructuredFacts(
        what: 'engineering manager you work with at Google',
        keyFacts: ['Lives in SF'],
        recentThemes: ['perf reviews'],
        relationship: 'colleague',
        lastMergedLogId: 'log_old',
      );
      final prompt = entitySummaryIncrementalPrompt(
        input: input,
        currentFacts: facts,
        newLogTitles: input.recentLogTitles,
        newLogSnippets: input.recentLogSnippets,
      );
      expect(prompt, contains('EXISTING facts'));
      expect(prompt, contains('engineering manager you work with at Google'));
      expect(prompt, contains('Lives in SF'));
      expect(prompt, contains('- New mention log'));
      expect(prompt, contains('> Shivani moved to the Mumbai office.'));
      expect(prompt, contains('Merge rules'));
    });
  });

  group('parseEntitySummaryGeneration', () {
    test('extracts both the summary and structured facts', () {
      final result = parseEntitySummaryGeneration(
        '{"summary":"You discussed Atlas with Shivani recently.",'
        '"facts":{"what":"colleague at Google",'
        '"key_facts":["Lives in SF","Started 2024-03"],'
        '"recent_themes":["sprint planning","perf reviews"],'
        '"relationship":"colleague"}}',
      );
      expect(result, isNotNull);
      expect(result!.summary, contains('Atlas'));
      expect(result.facts.what, 'colleague at Google');
      expect(result.facts.keyFacts, hasLength(2));
      expect(result.facts.relationship, 'colleague');
    });

    test('returns generation with empty facts when facts key is missing', () {
      final result = parseEntitySummaryGeneration(
        '{"summary":"You discussed Atlas with Shivani recently."}',
      );
      expect(result, isNotNull);
      expect(result!.facts.what, '');
      expect(result.facts.keyFacts, isEmpty);
    });

    test('caps key_facts at the documented max', () {
      final tooMany = List.generate(20, (i) => '"fact $i"').join(',');
      final result = parseEntitySummaryGeneration(
        '{"summary":"A nice long enough summary for the floor check.",'
        '"facts":{"what":"x","key_facts":[$tooMany],"recent_themes":[]}}',
      );
      expect(result, isNotNull);
      expect(result!.facts.keyFacts.length, kMaxKeyFacts);
    });

    test('returns null when the response is not JSON', () {
      expect(parseEntitySummaryGeneration('not json at all'), isNull);
    });

    test('returns null when the summary is below the minimum length', () {
      expect(
        parseEntitySummaryGeneration('{"summary":"too short","facts":{}}'),
        isNull,
      );
    });
  });

  group('parseEntitySummaryResponse (legacy alias)', () {
    test('still extracts the summary string', () {
      final result = parseEntitySummaryResponse(
        '{"summary":"You met Shivani for coffee to plan Project Atlas."}',
      );
      expect(result, 'You met Shivani for coffee to plan Project Atlas.');
    });
  });

  group('EntityStructuredFacts encoding', () {
    test('round-trips through encode/decode', () {
      const facts = EntityStructuredFacts(
        what: 'colleague at Google',
        keyFacts: ['Lives in SF'],
        recentThemes: ['sprint planning'],
        relationship: 'colleague',
        lastMergedLogId: 'log_42',
        lastFullRebuildAt: 12345,
        lastFullRebuildMentionCount: 7,
      );
      final encoded = EntityStructuredFacts.encode(facts);
      expect(encoded, isNotNull);
      final decoded = EntityStructuredFacts.decode(encoded);
      expect(decoded, isNotNull);
      expect(decoded!.what, facts.what);
      expect(decoded.keyFacts, facts.keyFacts);
      expect(decoded.relationship, 'colleague');
      expect(decoded.lastMergedLogId, 'log_42');
      expect(decoded.lastFullRebuildMentionCount, 7);
    });

    test('decode returns null on garbage input', () {
      expect(EntityStructuredFacts.decode(null), isNull);
      expect(EntityStructuredFacts.decode(''), isNull);
      expect(EntityStructuredFacts.decode('not json'), isNull);
    });
  });

  group('synthesizeFallbackEntitySummary', () {
    test('uses log titles when present', () {
      const input = EntitySummaryPromptInput(
        displayName: 'Shivani',
        type: 'PERSON',
        mentionCount: 3,
        recentLogTitles: ['Coffee with Shivani', 'Atlas standup notes'],
        recentLogSnippets: [],
      );
      final result = synthesizeFallbackEntitySummary(input);
      expect(result, contains('3 logs'));
      expect(result, contains('Coffee with Shivani'));
    });

    test('uses a typed phrase when titles are missing', () {
      const input = EntitySummaryPromptInput(
        displayName: 'Cafe Coffee Day',
        type: 'PLACE',
        mentionCount: 1,
        recentLogTitles: [],
        recentLogSnippets: [],
      );
      final result = synthesizeFallbackEntitySummary(input);
      expect(result, contains('1 log'));
      expect(result, contains('place'));
    });
  });
}
