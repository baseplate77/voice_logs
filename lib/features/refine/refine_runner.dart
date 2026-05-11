import '../../core/app_error.dart';
import '../../core/db/job_state.dart';
import '../../core/db/repositories/entity_mention_repository.dart';
import '../../core/db/repositories/voice_log_repository.dart';
import '../../core/logger.dart';
import '../../core/result.dart';
import '../../core/worker/job_handler.dart';
import '../../core/worker/job_queue.dart';
import 'llm_runner.dart';
import 'offset_recovery.dart';
import 'prompt_templates.dart';
import 'response_parser.dart';
import 'transcript_chunker.dart';

/// Refine handler for Gemma 3 1B.
///
/// Gemma 3 1B scored much better when cleanup and entity extraction were split
/// into two focused JSON tasks. The handler first cleans the raw transcript,
/// then asks for exact-substring entities from that cleaned text. Each stage has
/// one stricter retry; cleanup failure falls back to the raw transcript and
/// entity failure falls back to no mentions so embed/canonicalize jobs always
/// have a row to process.
class LlmRefiner implements JobHandler {
  LlmRefiner({
    required this.runner,
    required this.voiceLogs,
    required this.mentions,
    required this.queue,
  });

  final LlmRunner runner;
  final VoiceLogRepository voiceLogs;
  final EntityMentionRepository mentions;
  final JobQueue queue;

  final _log = Logger('llm_refiner');

  @override
  JobType get type => JobType.refine;

  @override
  Future<Result<JobOutcome, AppError>> handle(JobContext ctx) async {
    final total = Stopwatch()..start();
    _log.i(
      'Refine start job=${ctx.jobId} log=${ctx.logId} '
      'attempt=${ctx.attempts}',
    );

    final log = await voiceLogs.find(ctx.logId);
    if (log == null) {
      _log.w('Refine aborted: log not found after ${total.elapsed}');
      return const Ok(JobFailedPermanently('log not found'));
    }

    final rawTranscript = log.rawTranscript;
    _log.i('Refine input log=${ctx.logId}: chars=${rawTranscript.length}');
    if (rawTranscript.trim().isEmpty) {
      await voiceLogs.markRefined(id: ctx.logId, cleanedText: rawTranscript);
      await queue.enqueue(logId: ctx.logId, type: JobType.embed);
      _log.i('Refine complete (empty transcript) in ${total.elapsed}');
      return const Ok(JobSucceeded());
    }

    final loaded = await runner.load();
    switch (loaded) {
      case Ok():
        break;
      case Err(:final error):
        _log.w('Refine failed during LLM load', error: error);
        return Err(error);
    }

    final cleanup = await _cleanupTranscript(rawTranscript);
    final String? cleanedText;
    switch (cleanup) {
      case Ok(:final value):
        cleanedText = value;
      case Err(:final error):
        _log.w('Refine failed during cleanup generation', error: error);
        return Err(error);
    }
    if (cleanedText == null) {
      _log.w('Refine cleanup failed or dropped content; using raw transcript');
    }
    final finalCleanedText = cleanedText ?? rawTranscript;

    final Result<List<({String text, String type})>, LlmError> entityResult =
        cleanedText == null
        ? const Ok(<({String text, String type})>[])
        : await _extractEntitiesForTranscript(finalCleanedText);
    final List<({String text, String type})> parsedMentions;
    switch (entityResult) {
      case Ok(:final value):
        parsedMentions = value;
      case Err(:final error):
        _log.w('Refine failed during entity generation', error: error);
        return Err(error);
    }
    final located = recoverOffsets(
      cleanedText: finalCleanedText,
      mentions: parsedMentions,
    );
    _log.i(
      'Refine parsed: cleanedChars=${finalCleanedText.length}, '
      'entities=${parsedMentions.length}, located=${located.length}',
    );

    final markRes = await voiceLogs.markRefined(
      id: ctx.logId,
      cleanedText: finalCleanedText,
    );
    switch (markRes) {
      case Ok():
        break;
      case Err(:final error):
        _log.w('Refine failed while saving cleaned text', error: error);
        return Err(error);
    }

    final mentionRes = await mentions.replaceForLog(
      logId: ctx.logId,
      mentions: located,
    );
    switch (mentionRes) {
      case Ok():
        break;
      case Err(:final error):
        _log.w('Refine failed while saving mentions', error: error);
        return Err(error);
    }

    await queue.enqueue(logId: ctx.logId, type: JobType.embed);
    _log.i('Refine complete in ${total.elapsed}');
    return const Ok(JobSucceeded());
  }

  Future<Result<String?, LlmError>> _cleanupTranscript(
    String rawTranscript,
  ) async {
    final chunks = splitTranscriptForRefine(rawTranscript);
    if (chunks.length <= 1) return _cleanupChunk(rawTranscript);

    _log.i('Cleanup chunked into ${chunks.length} chunks');
    final cleanedChunks = <String>[];
    for (var i = 0; i < chunks.length; i++) {
      final chunk = chunks[i];
      final result = await _cleanupChunk(chunk.text);
      switch (result) {
        case Ok(:final value):
          cleanedChunks.add(value ?? chunk.text);
        case Err(:final error):
          return Err(error);
      }
    }
    return Ok(_joinCleanedChunks(cleanedChunks));
  }

  Future<Result<String?, LlmError>> _cleanupChunk(String rawTranscript) async {
    final first = await runner.generate(
      cleanupTranscriptPrompt(rawTranscript),
      temperature: kRecordLogTemperature,
    );
    String rawResponse;
    switch (first) {
      case Ok(:final value):
        rawResponse = value;
        _log.i('Cleanup response chars=${value.length}');
      case Err(:final error):
        return Err(error);
    }

    var cleaned = parseCleanedTranscript(rawResponse);
    if (cleaned != null) {
      if (_isCleanupContentPreserved(rawTranscript, cleaned)) {
        return Ok(cleaned);
      }
      _log.w('Cleanup dropped content; retrying with preservation prompt');
      return _retryCleanupForPreservation(rawTranscript, cleaned);
    }

    _log.w('Cleanup parse failed; retrying with stricter prompt');
    final retry = await runner.generate(
      cleanupTranscriptRetryPrompt(rawTranscript, rawResponse),
      temperature: kRecordLogTemperature,
    );
    switch (retry) {
      case Ok(:final value):
        cleaned = parseCleanedTranscript(value);
      case Err(:final error):
        return Err(error);
    }
    if (cleaned == null) return const Ok(null);
    if (_isCleanupContentPreserved(rawTranscript, cleaned)) return Ok(cleaned);
    _log.w('Cleanup retry dropped content; falling back to raw transcript');
    return const Ok(null);
  }

  Future<Result<String?, LlmError>> _retryCleanupForPreservation(
    String rawTranscript,
    String previousCleanedText,
  ) async {
    final retry = await runner.generate(
      cleanupTranscriptPreservationRetryPrompt(
        rawTranscript,
        previousCleanedText,
      ),
      temperature: kRecordLogTemperature,
    );
    String? cleaned;
    switch (retry) {
      case Ok(:final value):
        cleaned = parseCleanedTranscript(value);
      case Err(:final error):
        return Err(error);
    }
    if (cleaned == null) return const Ok(null);
    if (_isCleanupContentPreserved(rawTranscript, cleaned)) return Ok(cleaned);
    _log.w('Preservation retry still dropped content; falling back to raw');
    return const Ok(null);
  }

  Future<Result<List<({String text, String type})>, LlmError>>
  _extractEntitiesForTranscript(String cleanedText) async {
    final chunks = splitTranscriptForRefine(cleanedText);
    if (chunks.length <= 1) return _extractEntitiesChunk(cleanedText);

    _log.i('Entity extraction chunked into ${chunks.length} chunks');
    final allMentions = <({String text, String type})>[];
    for (final chunk in chunks) {
      final result = await _extractEntitiesChunk(chunk.text);
      switch (result) {
        case Ok(:final value):
          allMentions.addAll(value);
        case Err(:final error):
          return Err(error);
      }
    }
    return Ok(allMentions);
  }

  Future<Result<List<({String text, String type})>, LlmError>>
  _extractEntitiesChunk(String cleanedText) async {
    final first = await runner.generate(
      entityExtractionPrompt(cleanedText),
      temperature: kRecordLogTemperature,
    );
    String rawResponse;
    switch (first) {
      case Ok(:final value):
        rawResponse = value;
        _log.i('Entity response chars=${value.length}');
      case Err(:final error):
        return Err(error);
    }

    var mentions = parseEntityMentions(rawResponse, cleanedText: cleanedText);
    if (mentions != null) return Ok(mentions);

    _log.w('Entity parse failed; retrying with stricter prompt');
    final retry = await runner.generate(
      entityExtractionRetryPrompt(cleanedText, rawResponse),
      temperature: kRecordLogTemperature,
    );
    switch (retry) {
      case Ok(:final value):
        mentions = parseEntityMentions(value, cleanedText: cleanedText);
      case Err(:final error):
        return Err(error);
    }
    if (mentions == null) {
      _log.w('Entity retry parse failed; continuing with no mentions');
      return const Ok([]);
    }
    return Ok(mentions);
  }
}

String _joinCleanedChunks(List<String> chunks) {
  final buffer = StringBuffer();
  for (final chunk in chunks) {
    final text = chunk.trim();
    if (text.isEmpty) continue;
    if (buffer.isEmpty) {
      buffer.write(text);
      continue;
    }
    final current = buffer.toString();
    final needsSpace =
        !_endsWithWhitespace(current) && !_startsWithWhitespace(text);
    if (needsSpace) buffer.write(' ');
    buffer.write(text);
  }
  return buffer.toString();
}

bool _endsWithWhitespace(String text) {
  if (text.isEmpty) return false;
  return RegExp(r'\s').hasMatch(text[text.length - 1]);
}

bool _startsWithWhitespace(String text) {
  if (text.isEmpty) return false;
  return RegExp(r'\s').hasMatch(text[0]);
}

bool _isCleanupContentPreserved(String rawTranscript, String cleanedText) {
  final rawWords = _wordTokens(rawTranscript);
  final cleanedWords = _wordTokens(cleanedText);
  if (rawWords.isEmpty) return true;
  if (cleanedWords.isEmpty) return false;

  final wordRetention = cleanedWords.length / rawWords.length;
  final double requiredWordRetention;
  final double requiredContentRecall;
  if (rawWords.length >= 80) {
    requiredWordRetention = 0.85;
    requiredContentRecall = 0.65;
  } else if (rawWords.length >= 40) {
    requiredWordRetention = 0.80;
    requiredContentRecall = 0.60;
  } else {
    requiredWordRetention = 0.85;
    requiredContentRecall = 0.70;
  }
  if (wordRetention < requiredWordRetention) return false;

  final rawContent = _contentTokenCounts(rawWords);
  if (rawContent.isEmpty) return true;
  final cleanedContent = _contentTokenCounts(cleanedWords);
  var preserved = 0;
  var total = 0;
  for (final entry in rawContent.entries) {
    total += entry.value;
    final cleanedCount = cleanedContent[entry.key] ?? 0;
    preserved += cleanedCount > entry.value ? entry.value : cleanedCount;
  }

  final contentRecall = preserved / total;
  return contentRecall >= requiredContentRecall;
}

List<String> _wordTokens(String text) {
  return RegExp(
    r"[a-zA-Z0-9]+(?:'[a-zA-Z0-9]+)?",
  ).allMatches(text.toLowerCase()).map((m) => m.group(0)!).toList();
}

Map<String, int> _contentTokenCounts(List<String> words) {
  final counts = <String, int>{};
  for (final word in words) {
    if (word.length < 3 || _lowSignalWords.contains(word)) continue;
    counts.update(word, (value) => value + 1, ifAbsent: () => 1);
  }
  return counts;
}

const Set<String> _lowSignalWords = {
  'the',
  'and',
  'for',
  'with',
  'that',
  'this',
  'from',
  'have',
  'has',
  'had',
  'was',
  'were',
  'are',
  'but',
  'not',
  'you',
  'your',
  'our',
  'out',
  'about',
  'like',
  'then',
  'there',
  'here',
};
