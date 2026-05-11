import 'dart:math' as math;

import '../memory/memory_types.dart';
import '../search/hybrid_retriever.dart';

/// Total character budget for all context items (memories + logs).
const int kContextCharBudget = 2100;

/// Minimum chars per context item to be worth including.
const int kMinItemChars = 80;

/// Maximum number of memory cards considered for the prompt.
const int kAskPromptMemoryLimit = 3;

/// Maximum number of voice-log hits considered for the prompt.
const int kAskPromptLogLimit = 5;

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
  return switch (format) {
    QueryFormat.list =>
      'Answer as a markdown bullet list. Each item on its own line '
          'starting with "- ". Cite sources as [M1], [L2] inline.',
    QueryFormat.comparison =>
      'Answer as a markdown table with columns for each item being '
          'compared. Use pipe-delimited rows: | Aspect | A | B |. '
          'Cite sources as [M1], [L2] inline.',
    QueryFormat.factual =>
      'Answer in one concise sentence with [M1]/[L2] citations. '
          'No extra headings.',
    QueryFormat.summary =>
      'Answer in 2-4 sentences as a paragraph. '
          'Cite sources as [M1], [L2] inline.',
    QueryFormat.general =>
      'Use this structure:\n'
          '## Answer\n'
          'Direct answer in 1-3 sentences with [M1]/[L2] citations.\n'
          '## Evidence\n'
          '- Cite which sources support each claim.',
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

  final buffer = StringBuffer()
    ..writeln('You are VoxSynth, an on-device voice journal assistant.')
    ..writeln(
      'Answer ONLY from the context below. If the answer is not in the '
      'context, say exactly: "I don\'t have enough context from your '
      'voice logs to answer that."',
    )
    ..writeln(
      'Do NOT use outside knowledge. Do NOT guess. '
      'Cite sources as [M1], [L2], etc.',
    )
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

  buffer
    ..writeln()
    ..writeln('Question: $question')
    ..writeln()
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
    final date = hit.createdAt != null
        ? '(${_formatShortDate(hit.createdAt!)}) '
        : '';
    scored.add((
      label: '[L${i + 1}] $date',
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

String _formatShortDate(DateTime dt) => '${_months[dt.month - 1]} ${dt.day}';
