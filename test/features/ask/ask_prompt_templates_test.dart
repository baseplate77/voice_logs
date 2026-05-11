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
      expect(prompt, contains('bullet list'));
      expect(prompt, isNot(contains('## Answer')));
    });

    test('uses comparison format for comparison queries', () {
      final prompt = buildAskPrompt(
        question: 'Compare project A vs project B',
        memoryHits: [],
        logHits: [_logHit('log_1', 0.5, 'project details here')],
      );
      expect(prompt, contains('table'));
    });

    test('uses factual format for factual queries', () {
      final prompt = buildAskPrompt(
        question: 'When did I meet Raj?',
        memoryHits: [],
        logHits: [_logHit('log_1', 0.5, 'Met Raj on May 5.')],
      );
      expect(prompt, contains('one concise sentence'));
    });

    test('uses general format with headings for general queries', () {
      final prompt = buildAskPrompt(
        question: 'What do I prefer?',
        memoryHits: [_memoryHit()],
        logHits: [],
      );
      expect(prompt, contains('## Answer'));
      expect(prompt, contains('## Evidence'));
    });

    test('includes date labels on log snippets', () {
      final prompt = buildAskPrompt(
        question: 'test',
        memoryHits: [],
        logHits: [_logHit('log_1', 0.5, 'content', date: DateTime(2026, 5, 8))],
      );
      expect(prompt, contains('(May 8)'));
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
