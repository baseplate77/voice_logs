import 'package:flutter_test/flutter_test.dart';
import 'package:voxsynth/features/ask/ask_prompt_templates.dart';
import 'package:voxsynth/features/memory/memory_types.dart';
import 'package:voxsynth/features/search/hybrid_retriever.dart';

void main() {
  group('classifyQuery', () {
    test('detects list queries', () {
      expect(
        classifyQuery('List all the projects I mentioned this week'),
        QueryFormat.list,
      );
      expect(classifyQuery('What tasks do I have?'), QueryFormat.list);
      expect(
        classifyQuery('Show me every person I talked about'),
        QueryFormat.list,
      );
    });

    test('detects comparison queries', () {
      expect(
        classifyQuery('Compare project A vs project B'),
        QueryFormat.comparison,
      );
      expect(
        classifyQuery('What is the difference between the two meetings?'),
        QueryFormat.comparison,
      );
      expect(
        classifyQuery('Contrast my morning and evening routine'),
        QueryFormat.comparison,
      );
    });

    test('detects factual queries', () {
      expect(classifyQuery('When did I meet Raj?'), QueryFormat.factual);
      expect(classifyQuery('Where was the meeting?'), QueryFormat.factual);
      expect(classifyQuery('Did I mention the deadline?'), QueryFormat.factual);
      expect(classifyQuery('How long was the call?'), QueryFormat.factual);
    });

    test('detects summary queries', () {
      expect(classifyQuery('Summarize my week'), QueryFormat.summary);
      expect(classifyQuery('What happened today?'), QueryFormat.summary);
      expect(classifyQuery('Give me a recap'), QueryFormat.summary);
    });

    test('falls back to general for ambiguous queries', () {
      expect(classifyQuery('What app style do I prefer?'), QueryFormat.general);
      expect(classifyQuery('Tell me about my diet'), QueryFormat.general);
    });
  });

  group('buildAskPrompt', () {
    test('uses list format instruction for list queries', () {
      final prompt = buildAskPrompt(
        question: 'List all projects',
        memoryHits: [],
        logHits: [_logHit('log_1', 0.5, 'I worked on project Atlas.')],
      );
      // Template-placeholder scaffold instead of descriptive prose, so the
      // model substitutes rather than copies.
      expect(prompt, contains('<topic 1, citation>'));
    });

    test('uses comparison format for comparison queries', () {
      final prompt = buildAskPrompt(
        question: 'Compare project A vs project B',
        memoryHits: [],
        logHits: [_logHit('log_1', 0.5, 'project details here')],
      );
      expect(prompt, contains('| Aspect | A | B |'));
    });

    test('uses factual format for factual queries', () {
      final prompt = buildAskPrompt(
        question: 'When did I meet Raj?',
        memoryHits: [],
        logHits: [_logHit('log_1', 0.5, 'Met Raj on May 5.')],
      );
      expect(prompt, contains('one or two sentences'));
      // Factual answers are intentionally header-less: a single tight
      // paragraph reads better than `## Answer` for one-line facts.
      expect(prompt, isNot(contains('## Answer')));
    });

    test('uses general format with headings for general queries', () {
      final prompt = buildAskPrompt(
        question: 'What do I prefer?',
        memoryHits: [_memoryHit()],
        logHits: [],
      );
      expect(prompt, contains('## Answer'));
      // Details section is marked optional so the model isn't forced to
      // fill it when the context only supports a one-line answer.
      expect(prompt, contains('## Details (omit if'));
    });

    test('never asks the model to write an Evidence/Sources section', () {
      // The UI renders sources unconditionally under every answer. Asking
      // the model to recap them produced duplicate text and triggered
      // verbatim parroting on the 1B model (the bug in the screenshot).
      for (final q in [
        'List all projects',
        'Compare A vs B',
        'When did I meet Raj?',
        'Summarize Friday',
        'What is going on with Atlas?',
      ]) {
        final prompt = buildAskPrompt(
          question: q,
          memoryHits: [],
          logHits: [_logHit('log_1', 0.5, 'placeholder content')],
        );
        expect(
          prompt,
          isNot(contains('## Evidence')),
          reason: 'Evidence section must be dropped for query: "$q"',
        );
      }
    });

    test('never reintroduces the parroted placeholder bullets', () {
      // These exact phrases used to appear inside the prompt and small
      // models copy-pasted them into their answers. The new prompt uses
      // directive language ("write 3-6 bullets…") instead.
      for (final q in ['Summarize today', 'What happened with Atlas?']) {
        final prompt = buildAskPrompt(
          question: q,
          memoryHits: [],
          logHits: [_logHit('log_1', 0.5, 'placeholder content')],
        );
        expect(prompt, isNot(contains('Source-backed bullets for')));
        expect(
          prompt,
          isNot(contains('Cite which sources support each claim')),
        );
      }
    });

    test('system preamble + format scaffold stay short to prevent loops', () {
      // Long preambles dilute attention on 1B models and cause looping.
      // The whole pre-Context portion (system + rules + format) must
      // stay under ~140 words. If a future change pushes it past this
      // threshold, revisit whether each new line is really necessary.
      for (final q in [
        'List all projects',
        'Compare A vs B',
        'When did I meet Raj?',
        'Summarize Friday',
        'What is going on?',
      ]) {
        final prompt = buildAskPrompt(
          question: q,
          memoryHits: [],
          logHits: [_logHit('log_1', 0.5, 'placeholder')],
        );
        final preamble = prompt.split('Context:').first;
        final wordCount = preamble
            .split(RegExp(r'\s+'))
            .where((w) => w.isNotEmpty)
            .length;
        expect(
          wordCount,
          lessThan(140),
          reason:
              'Preamble for "$q" grew to $wordCount words. Compress or '
              'remove a directive — long preambles trigger loops.',
        );
      }
    });

    test('stop directive sits right before "Answer:" as a recency anchor', () {
      // The model gives the last instruction the most attention. Burying
      // anti-loop guidance in the system preamble does not work on 1B
      // models — it has to be the line immediately preceding `Answer:`.
      final prompt = buildAskPrompt(
        question: 'Anything',
        memoryHits: [],
        logHits: [_logHit('log_1', 0.5, 'content')],
      );
      final lines = prompt.split('\n');
      final answerIdx = lines.lastIndexWhere((l) => l.startsWith('Answer:'));
      expect(answerIdx, greaterThan(0));
      final previous = lines[answerIdx - 1];
      expect(previous, contains('Stop'));
      expect(previous.toLowerCase(), contains('do not repeat'));
    });

    test('prompt no longer contains contradictory verbosity directives', () {
      // "Prefer a detailed... do not be overly terse" was the primary loop
      // trigger — it fought the "stop when done" rule. Lock both phrases
      // out of the prompt going forward.
      final prompt = buildAskPrompt(
        question: 'Anything',
        memoryHits: [],
        logHits: [_logHit('log_1', 0.5, 'content')],
      );
      expect(prompt, isNot(contains('Prefer a detailed')));
      expect(prompt, isNot(contains('not be overly terse')));
      expect(prompt, isNot(contains('NEVER repeat')));
    });

    test('includes date labels on log snippets', () {
      final prompt = buildAskPrompt(
        question: 'test',
        memoryHits: [],
        logHits: [_logHit('log_1', 0.5, 'content', date: DateTime(2026, 5, 8))],
      );
      expect(prompt, contains('May 8 log'));
    });

    test('allocates more budget to higher-scoring hits', () {
      final prompt = buildAskPrompt(
        question: 'test query',
        memoryHits: [],
        logHits: [
          _logHit('high', 0.9, 'A' * 800),
          _logHit('low', 0.1, 'B' * 800),
        ],
      );
      final highContent =
          RegExp(r'\[L1\].*?(A+)').firstMatch(prompt)?.group(1) ?? '';
      final lowContent =
          RegExp(r'\[L2\].*?(B+)').firstMatch(prompt)?.group(1) ?? '';
      expect(
        highContent.length,
        greaterThan(lowContent.length),
        reason: 'higher-scoring hit should get more chars',
      );
    });

    test('includes full text for short logs', () {
      final prompt = buildAskPrompt(
        question: 'test',
        memoryHits: [],
        logHits: [
          const SearchHit(
            logId: 'short',
            fusedScore: 0.5,
            matchedVia: {MatchSource.fts},
            snippet: 'Short log content here.',
            fullText: 'Short log content here.',
          ),
        ],
      );
      expect(prompt, contains('Short log content here.'));
    });

    test('joins multiple segments for multi-segment hits', () {
      final prompt = buildAskPrompt(
        question: 'test',
        memoryHits: [],
        logHits: [
          SearchHit(
            logId: 'multi',
            fusedScore: 0.5,
            matchedVia: {MatchSource.vector},
            snippet: 'First segment.',
            segments: ['First segment.', 'Second segment.'],
            fullText: 'A' * 2000,
          ),
        ],
      );
      expect(prompt, contains('First segment.'));
      expect(prompt, contains('Second segment.'));
    });

    test('shows none when context is empty', () {
      final prompt = buildAskPrompt(
        question: 'anything',
        memoryHits: [],
        logHits: [],
      );
      expect(prompt, contains('- none'));
    });
  });
}

SearchHit _logHit(String id, double score, String text, {DateTime? date}) {
  return SearchHit(
    logId: id,
    fusedScore: score,
    matchedVia: {MatchSource.fts},
    snippet: text,
    createdAt: date,
  );
}

MemoryHit _memoryHit() {
  return MemoryHit(
    memory: MemoryItemView(
      id: 'mem_1',
      type: MemoryType.preference,
      text: 'User prefers local-first privacy-preserving apps.',
      normalizedText: 'user prefers local first privacy preserving apps',
      confidence: 0.95,
      status: MemoryStatus.active,
      sensitivity: MemorySensitivity.normal,
      firstSeenAt: DateTime(2026, 5),
      lastSeenAt: DateTime(2026, 5),
      createdAt: DateTime(2026, 5),
      updatedAt: DateTime(2026, 5),
      embedding: null,
    ),
    fusedScore: 0.5,
    matchedVia: const {MemoryMatchSource.fts},
  );
}
