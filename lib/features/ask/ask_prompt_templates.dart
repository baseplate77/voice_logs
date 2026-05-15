import 'dart:math' as math;

import '../memory/memory_types.dart';
import '../search/hybrid_retriever.dart';

/// Total character budget for all context items (memories + logs).
const int kContextCharBudget = 3200;

/// Minimum chars per context item to be worth including.
const int kMinItemChars = 120;

/// Maximum number of memory cards considered for the prompt.
const int kAskPromptMemoryLimit = 3;

/// Maximum number of voice-log hits considered for the prompt.
const int kAskPromptLogLimit = 8;

const _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

/// Query intent used to pick the best response format.
enum QueryFormat { list, comparison, factual, summary, general }

/// Classify a user question into a response format via keyword patterns.
QueryFormat classifyQuery(String question) {
  final q = question.toLowerCase().trim();

  if (RegExp(
        r'\b(compare|versus|vs\.?|difference|differ|contrast)\b',
      ).hasMatch(q) ||
      RegExp(r'\bbetween\b.*\band\b').hasMatch(q)) {
    return QueryFormat.comparison;
  }
  if (RegExp(r'\b(list|all|every|each)\b').hasMatch(q) ||
      RegExp(r'\bhow many\b').hasMatch(q) ||
      RegExp(
        r'\bwhat (tasks?|projects?|things?|items?|people|names?)\b',
      ).hasMatch(q)) {
    return QueryFormat.list;
  }
  if (RegExp(
        r'\b(when|what time|what date|where|who is|how long)\b',
      ).hasMatch(q) ||
      RegExp(r'\bdid (i|we)\b').hasMatch(q)) {
    return QueryFormat.factual;
  }
  if (RegExp(
    r'\b(summarize|summary|recap|overview|what happened)\b',
  ).hasMatch(q)) {
    return QueryFormat.summary;
  }
  return QueryFormat.general;
}

String _formatInstruction(QueryFormat format) {
  // Each scaffold is intentionally tiny. The 1B model loops when given long
  // structural prose to imitate, so we use angle-bracket placeholders
  // (`<answer>`) instead of descriptive prose (`A 2-4 sentence direct
  // answer…`). Placeholders signal "substitute me", prose tempts the model
  // to copy. Section headers (`## Details`) are flagged optional so the
  // model isn't forced to fill a section it has nothing for.
  return switch (format) {
    QueryFormat.factual =>
      'Format: one or two sentences, inline citations. No headings.',
    QueryFormat.list =>
      'Format:\n'
          '- <topic 1, citation>\n'
          '- <topic 2, citation>',
    QueryFormat.comparison =>
      'Format (markdown table, one row per differentiator):\n'
          '| Aspect | A | B |\n'
          '| --- | --- | --- |\n'
          '| <aspect> | <A value, citation> | <B value, citation> |',
    QueryFormat.summary =>
      'Format:\n'
          '## Summary\n'
          '<one paragraph, inline citations>\n'
          '## Highlights\n'
          '- <bullet, citation>',
    QueryFormat.general =>
      'Format:\n'
          '## Answer\n'
          '<answer, inline citations>\n'
          '## Details (omit if the answer is already complete)\n'
          '- <bullet, citation>',
  };
}

/// Builds the local RAG prompt used to answer a user question from retrieved
/// voice-log and memory context. Context budget is distributed proportionally
/// by relevance score.
String buildAskPrompt({
  required String question,
  required List<MemoryHit> memoryHits,
  required List<SearchHit> logHits,
}) {
  final format = classifyQuery(question);

  // Compact, directive preamble. Past iterations stacked four paragraphs of
  // instructions that competed for the 1B model's attention and contained
  // contradictions ("be detailed" vs. "stop writing"). The minimal version
  // below leans on recency: the stop directive lives right before the
  // generation cursor (`Answer:`) where the model attends most.
  final buffer = StringBuffer()
    ..writeln(
      'You are VoxSynth, a voice journal assistant. '
      'Answer using ONLY the Context below.',
    )
    ..writeln()
    ..writeln('Rules:')
    ..writeln('- Cite every claim with [L#] or [M#] from the Context.')
    ..writeln(
      '- Match the answer length to the Context. '
      'One sentence is a complete answer when one sentence is all that fits.',
    )
    ..writeln(
      '- If the Context does not answer the question, reply exactly: '
      '"I don\'t have enough context from your voice logs to answer that."',
    )
    ..writeln()
    ..writeln(_formatInstruction(format))
    ..writeln()
    ..writeln('Context:');

  final items = _allocateContext(
    memories: memoryHits,
    logs: logHits,
    totalBudget: kContextCharBudget,
  );

  if (items.isEmpty) {
    buffer.writeln('- none');
  } else {
    for (final item in items) {
      buffer.writeln('${item.label} ${item.content}');
    }
  }

  // Recency anchor: small models give the last instruction the most
  // attention. Placing the stop directive immediately before `Answer:`
  // dramatically reduces phrase loops compared to burying it in the
  // preamble. Keep it short — one short sentence beats a paragraph.
  buffer
    ..writeln()
    ..writeln('Question: $question')
    ..writeln()
    ..writeln('Stop as soon as the answer is complete. Do not repeat.')
    ..writeln('Answer:');
  return buffer.toString();
}

/// Allocate the char budget across context items proportional to relevance.
List<({String label, String content})> _allocateContext({
  required List<MemoryHit> memories,
  required List<SearchHit> logs,
  required int totalBudget,
}) {
  final scored = <({String label, String rawContent, double score})>[];

  for (var i = 0; i < memories.length && i < kAskPromptMemoryLimit; i++) {
    final hit = memories[i];
    scored.add((
      label:
          '[M${i + 1}] ${hit.memory.type.wire}; '
          '${hit.memory.confidence.toStringAsFixed(2)}:',
      rawContent: hit.memory.text,
      score: hit.fusedScore,
    ));
  }

  for (var i = 0; i < logs.length && i < kAskPromptLogLimit; i++) {
    final hit = logs[i];
    scored.add((
      label: '[L${i + 1}] ${formatLogSourceLabel(hit)}:',
      rawContent: _bestLogText(hit),
      score: hit.fusedScore,
    ));
  }

  if (scored.isEmpty) return [];

  final totalScore = scored.fold<double>(0, (s, i) => s + i.score);
  final result = <({String label, String content})>[];
  var remaining = totalBudget;

  for (final item in scored) {
    if (remaining < kMinItemChars) break;
    final proportion = totalScore > 0
        ? item.score / totalScore
        : 1.0 / scored.length;
    final charAlloc = math
        .max(kMinItemChars, (totalBudget * proportion).round())
        .clamp(kMinItemChars, remaining);
    final clipped = _clip(item.rawContent, charAlloc);
    result.add((label: item.label, content: clipped));
    remaining -= clipped.length + item.label.length + 2;
  }

  return result;
}

/// Pick the richest available text for a log hit.
String _bestLogText(SearchHit hit) {
  final full = hit.fullText;
  if (full != null && full.length <= 800) return full;
  if (hit.segments.length > 1) return hit.segments.join(' … ');
  return hit.snippet;
}

String _clip(String text, int maxChars) {
  final compact = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (compact.length <= maxChars) return compact;
  return '${compact.substring(0, maxChars - 1).trimRight()}…';
}

/// User-facing source label for a voice log.
String formatLogSourceLabel(SearchHit hit) {
  final date = hit.createdAt != null
      ? '${_months[hit.createdAt!.month - 1]} ${hit.createdAt!.day} log'
      : 'Voice log';
  final title = hit.logTitle?.trim();
  if (title == null || title.isEmpty) return date;
  return '$date — $title';
}
