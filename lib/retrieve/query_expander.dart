import 'dart:convert';

import '../core/logger.dart';
import '../llm/llm_runner.dart';
import '../llm/prompt_templates.dart';

/// Query paraphrases + extracted entities the retriever fans out over.
final class ExpandedQuery {
  const ExpandedQuery({
    required this.original,
    required this.paraphrases,
    required this.entities,
  });

  final String original;
  final List<String> paraphrases;
  final List<String> entities;

  /// The queries that actually get searched against — one per
  /// paraphrase plus the original. Keeps the original first so the
  /// retriever can attribute rank contributions if it wants to.
  List<String> get allQueries => <String>[original, ...paraphrases];

  @override
  String toString() =>
      'ExpandedQuery("$original", ${paraphrases.length} paraphrases, '
      '${entities.length} entities)';
}

const PromptTemplate _queryExpansionTemplate = PromptTemplate(
  name: 'query_expansion',
  body: '''
You are VoxSynth's retrieval planner. Given a user query, produce
exactly 2 paraphrases that would plausibly retrieve the same answer
from a text corpus, plus any named entities (people, projects,
products, decisions) the query mentions.

Output ONLY a JSON object, no prose, no markdown fences:
  {"paraphrases": ["…", "…"], "entities": ["…", …]}

Rules:
- Paraphrases should vary vocabulary (synonyms, related terms) but
  preserve the question's intent.
- Entities stay verbatim — same case, same spelling as in the query.
- Empty entities array is fine if there are none.
- NEVER return more than 2 paraphrases.

User query:
{{query}}
''',
  requiredVariables: <String>['query'],
);

const PromptTemplate _queryExpansionRetryTemplate = PromptTemplate(
  name: 'query_expansion_retry',
  body: '''
Your last response was not valid JSON. Respond with ONLY a JSON
object in this exact shape — no prose, no markdown:

  {"paraphrases": ["…", "…"], "entities": []}

User query:
{{query}}
''',
  requiredVariables: <String>['query'],
);

/// Expands a user query into N paraphrases + entity mentions using an
/// [LlmRunner]. Degrades gracefully: on bad/missing LLM output,
/// returns the original query with no paraphrases and no entities —
/// retrieval still works (just with less recall via expansion).
class QueryExpander {
  QueryExpander({required this.runner, AppLogger? logger})
      : _logger = logger ?? AppLogger();

  final LlmRunner runner;
  final AppLogger _logger;

  /// Try expansion; on LLM failure or malformed JSON, retry once with
  /// a stricter prompt, then fall back to `{original, [], []}`.
  Future<ExpandedQuery> expand(String query) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) {
      return const ExpandedQuery(
        original: '',
        paraphrases: <String>[],
        entities: <String>[],
      );
    }

    final first = await runner.generateSync(
      _queryExpansionTemplate.render(<String, String>{'query': trimmed}),
    );
    if (first.isOk) {
      final parsed = _parse(first.okOrNull!);
      if (parsed != null) return _withOriginal(trimmed, parsed);
      _logger.warn('Query-expansion JSON parse failed; retrying');
    } else {
      _logger.warn(
        'Query-expansion LLM call failed; retrying',
        error: first.errOrNull,
      );
    }

    final retry = await runner.generateSync(
      _queryExpansionRetryTemplate.render(<String, String>{'query': trimmed}),
    );
    if (retry.isOk) {
      final parsed = _parse(retry.okOrNull!);
      if (parsed != null) return _withOriginal(trimmed, parsed);
    }
    _logger.warn('Query expansion failed after retry; using fallback');
    return ExpandedQuery(
      original: trimmed,
      paraphrases: const <String>[],
      entities: const <String>[],
    );
  }

  static ExpandedQuery _withOriginal(String original, _Parsed p) =>
      ExpandedQuery(
        original: original,
        // Cap at 2 — the prompt says so but defensive.
        paraphrases: p.paraphrases.take(2).toList(growable: false),
        entities: p.entities,
      );

  static _Parsed? _parse(String raw) {
    final cleaned = _stripCodeFences(raw);
    final Object? decoded;
    try {
      decoded = jsonDecode(cleaned);
    } on FormatException {
      return null;
    }
    if (decoded is! Map) return null;
    final p = decoded['paraphrases'];
    final e = decoded['entities'];
    if (p is! List) return null;
    final paraphrases = <String>[];
    for (final item in p) {
      if (item is! String || item.trim().isEmpty) continue;
      paraphrases.add(item.trim());
    }
    final entities = <String>[];
    if (e is List) {
      for (final item in e) {
        if (item is! String || item.trim().isEmpty) continue;
        entities.add(item.trim());
      }
    }
    return _Parsed(paraphrases: paraphrases, entities: entities);
  }

  static String _stripCodeFences(String raw) {
    var s = raw.trim();
    if (s.startsWith('```')) {
      final firstNl = s.indexOf('\n');
      if (firstNl >= 0) s = s.substring(firstNl + 1);
      if (s.endsWith('```')) s = s.substring(0, s.length - 3);
    }
    return s.trim();
  }
}

class _Parsed {
  const _Parsed({required this.paraphrases, required this.entities});
  final List<String> paraphrases;
  final List<String> entities;
}
