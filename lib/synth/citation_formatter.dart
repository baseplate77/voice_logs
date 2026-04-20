import '../memory/models/memory.dart';
import '../memory/models/ranked_memory.dart';
import '../retrieve/models/ranked_chunk.dart';
import '../store/models/voice_log_record.dart';
import 'models/synthesis_event.dart';
import 'multi_hop_retriever.dart';

/// Truncate chunk text when building the prompt. Gemma 3 1B has 8k
/// context — 5 chunks × 1500 chars leaves ~1.5k tokens of headroom
/// for the instruction + answer tokens.
const int kChunkMaxCharsInPrompt = 1500;

/// Separator between tagged chunks in the prompt. Blank line makes
/// the block easier for Gemma to parse.
const String _chunkSeparator = '\n\n';

/// Build the "Sources:" block for a RAG prompt. Each chunk is tagged
/// `[C1]`, `[C2]`, ...; tags are 1-based and match what the
/// [parseCitations] parser expects.
///
/// Returns both the formatted block and the mapping from tag → chunk
/// id so the caller can pass the mapping to [parseCitations] later.
({String block, Map<String, int> tagToChunkId}) formatChunksForPrompt(
  List<RankedChunk> chunks, {
  int maxCharsPerChunk = kChunkMaxCharsInPrompt,
}) {
  final buf = StringBuffer();
  final tagToChunkId = <String, int>{};
  for (var i = 0; i < chunks.length; i++) {
    final tag = 'C${i + 1}';
    final chunk = chunks[i].chunk;
    tagToChunkId[tag] = chunk.id;
    final text = chunk.text;
    final snippet = text.length > maxCharsPerChunk
        ? '${text.substring(0, maxCharsPerChunk).trim()}…'
        : text;
    if (buf.isNotEmpty) buf.write(_chunkSeparator);
    buf
      ..write('[')
      ..write(tag)
      ..write('] ')
      ..write(snippet);
  }
  return (block: buf.toString(), tagToChunkId: tagToChunkId);
}

/// Build the same block for a collection of [ChunkRecord]s — used by
/// multi-hop retrieval which hasn't produced RankedChunks yet.
({String block, Map<String, int> tagToChunkId}) formatRecordsForPrompt(
  List<ChunkRecord> chunks, {
  int maxCharsPerChunk = kChunkMaxCharsInPrompt,
}) {
  final buf = StringBuffer();
  final tagToChunkId = <String, int>{};
  for (var i = 0; i < chunks.length; i++) {
    final tag = 'C${i + 1}';
    tagToChunkId[tag] = chunks[i].id;
    final text = chunks[i].text;
    final snippet = text.length > maxCharsPerChunk
        ? '${text.substring(0, maxCharsPerChunk).trim()}…'
        : text;
    if (buf.isNotEmpty) buf.write(_chunkSeparator);
    buf
      ..write('[')
      ..write(tag)
      ..write('] ')
      ..write(snippet);
  }
  return (block: buf.toString(), tagToChunkId: tagToChunkId);
}

/// Format a list of [WeekCluster]s into the multi-hop prompt's Sources
/// block. Chunks are tagged `[C1]..[Cn]` globally across weeks (so the
/// LLM's citations resolve unambiguously) while still being grouped
/// under a `Week of YYYY-MM-DD:` header so it can narrate evolution.
///
/// The tag numbering walks weeks in the order supplied — pass the
/// clusters chronologically for a chronological prompt.
({String block, Map<String, int> tagToChunkId}) formatWeekClustersForPrompt(
  List<WeekCluster> weeks, {
  int maxCharsPerChunk = kChunkMaxCharsInPrompt,
}) {
  final buf = StringBuffer();
  final tagToChunkId = <String, int>{};
  var tagCounter = 0;
  for (var w = 0; w < weeks.length; w++) {
    final week = weeks[w];
    if (buf.isNotEmpty) buf.write(_chunkSeparator);
    final iso = week.weekStart.toIso8601String().substring(0, 10);
    buf.write('Week of $iso:\n');
    for (var i = 0; i < week.chunks.length; i++) {
      tagCounter++;
      final tag = 'C$tagCounter';
      final chunk = week.chunks[i].chunk;
      tagToChunkId[tag] = chunk.id;
      final text = chunk.text;
      final snippet = text.length > maxCharsPerChunk
          ? '${text.substring(0, maxCharsPerChunk).trim()}…'
          : text;
      if (i > 0) buf.write('\n');
      buf
        ..write('  [')
        ..write(tag)
        ..write('] ')
        ..write(snippet);
    }
  }
  return (block: buf.toString(), tagToChunkId: tagToChunkId);
}

/// Build the memory block for a RAG prompt. Each memory is tagged
/// `[M1]`, `[M2]`, ...; the tag → memory-id map is returned alongside
/// so the caller can pass it to [parseCitations] later.
///
/// Format mirrors the chunk block (same tag/content spacing) but
/// prefixes each entry with a kind + date hint so the LLM has enough
/// structure to cite correctly.
({String block, Map<String, String> tagToMemoryId})
    formatMemoriesForPrompt(List<RankedMemory> memories) {
  final buf = StringBuffer();
  final tagToMemoryId = <String, String>{};
  for (var i = 0; i < memories.length; i++) {
    final tag = 'M${i + 1}';
    final m = memories[i].memory;
    tagToMemoryId[tag] = m.id.raw;
    if (buf.isNotEmpty) buf.write(_chunkSeparator);
    buf
      ..write('[')
      ..write(tag)
      ..write('] ')
      ..write(_memoryHeader(m))
      ..write(' ')
      ..write(m.content);
  }
  return (block: buf.toString(), tagToMemoryId: tagToMemoryId);
}

String _memoryHeader(Memory m) {
  switch (m) {
    case FactMemory():
      return '(fact)';
    case DecisionMemory():
      return '(decision, ${_ymd(m.occurredAt)})';
    case EpisodeMemory():
      return '(episode, ${_ymd(m.occurredAt)})';
    case GoalMemory():
      final state = switch (m.state) {
        GoalState.open => 'open',
        GoalState.inProgress => 'in progress',
        GoalState.done => 'done',
        GoalState.abandoned => 'abandoned',
      };
      final due = m.dueAt == null ? '' : ', due ${_ymd(m.dueAt!)}';
      return '(goal, $state$due)';
  }
}

String _ymd(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

/// Pattern matching `[Cn]` or `[Mn]` where `n` is one or more digits.
/// Used for parsing citations out of the LLM's answer text.
final RegExp _citationRegex = RegExp(r'\[([CM]\d+)\]');

/// Parse `[Cn]` / `[Mn]` markers from the answer text into resolved
/// [Citation] objects.
///
/// Tags that don't appear in [tagToChunkId] or [tagToMemoryId] are
/// silently skipped — the LLM sometimes hallucinates `[C9]` when there
/// are only 5 chunks. The caller can compare counts to detect that.
List<Citation> parseCitations(
  String answer,
  Map<String, int> tagToChunkId, {
  Map<String, String> tagToMemoryId = const <String, String>{},
}) {
  final out = <Citation>[];
  for (final match in _citationRegex.allMatches(answer)) {
    final tag = match.group(1)!;
    if (tag.startsWith('C')) {
      final chunkId = tagToChunkId[tag];
      if (chunkId == null) continue;
      out.add(
        Citation(
          tag: tag,
          chunkId: chunkId,
          spanStart: match.start,
          spanEnd: match.end,
        ),
      );
    } else {
      final memoryId = tagToMemoryId[tag];
      if (memoryId == null) continue;
      out.add(
        Citation(
          tag: tag,
          memoryId: memoryId,
          sourceKind: CitationSourceKind.memory,
          spanStart: match.start,
          spanEnd: match.end,
        ),
      );
    }
  }
  return out;
}

/// Fast bool: "does this answer contain at least one valid citation?".
/// The synthesizer uses this to decide whether to retry with a
/// stricter prompt.
bool answerHasCitations(
  String answer,
  Map<String, int> tagToChunkId, {
  Map<String, String> tagToMemoryId = const <String, String>{},
}) =>
    parseCitations(
      answer,
      tagToChunkId,
      tagToMemoryId: tagToMemoryId,
    ).isNotEmpty;
