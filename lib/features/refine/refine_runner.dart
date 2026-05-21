import '../../core/app_error.dart';
import '../../core/db/job_state.dart';
import '../../core/db/repositories/entity_mention_repository.dart';
import '../../core/db/repositories/prompt_suggestion_repository.dart';
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
    this.suggestions,
  });

  final LlmRunner runner;
  final VoiceLogRepository voiceLogs;
  final EntityMentionRepository mentions;
  final JobQueue queue;

  /// Optional. When provided, refine runs a fourth Gemma stage that
  /// extracts tap-to-ask suggestion chips from the cleaned text. Suggestion
  /// failures never abort refine — the chip simply doesn't appear.
  final PromptSuggestionRepository? suggestions;

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
    final ParsedCleanupTranscript? cleaned;
    switch (cleanup) {
      case Ok(:final value):
        cleaned = value;
      case Err(:final error):
        _log.w('Refine failed during cleanup generation', error: error);
        return Err(error);
    }
    if (cleaned == null) {
      _log.w('Refine cleanup failed or dropped content; using raw transcript');
    }
    final finalCleanedText = cleaned?.cleanedText ?? rawTranscript;
    final titleAndFlower = await _resolveTitle(
      cleanedText: finalCleanedText,
      legacyTitle: cleaned?.title,
    );

    final Result<List<({String text, String type})>, LlmError> entityResult =
        cleaned == null
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
      title: titleAndFlower.title,
      flowerType: titleAndFlower.flowerType,
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

    // Suggestion stage — best-effort. Refine never fails on this path.
    if (suggestions != null && cleaned != null) {
      await _generateAndPersistSuggestions(
        logId: ctx.logId,
        cleanedText: finalCleanedText,
      );
    }

    await queue.enqueue(logId: ctx.logId, type: JobType.embed);
    await queue.enqueue(logId: ctx.logId, type: JobType.summarize);
    _log.i('Refine complete in ${total.elapsed}');
    return const Ok(JobSucceeded());
  }

  Future<Result<ParsedCleanupTranscript?, LlmError>> _cleanupTranscript(
    String rawTranscript,
  ) async {
    final chunks = splitTranscriptForRefine(rawTranscript);
    if (chunks.length <= 1) return _cleanupChunk(rawTranscript);

    _log.i('Cleanup chunked into ${chunks.length} chunks');
    final cleanedChunks = <String>[];
    String? title;
    for (var i = 0; i < chunks.length; i++) {
      final chunk = chunks[i];
      final result = await _cleanupChunk(chunk.text);
      switch (result) {
        case Ok(:final value):
          cleanedChunks.add(value?.cleanedText ?? chunk.text);
          title ??= value?.title;
        case Err(:final error):
          return Err(error);
      }
    }
    final cleaned = _joinCleanedChunks(cleanedChunks);
    return Ok(ParsedCleanupTranscript(cleanedText: cleaned, title: title));
  }

  Future<Result<ParsedCleanupTranscript?, LlmError>> _cleanupChunk(
    String rawTranscript,
  ) async {
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

    var cleaned = parseCleanupTranscript(rawResponse);
    if (cleaned != null) {
      if (_isCleanupContentPreserved(rawTranscript, cleaned.cleanedText)) {
        return Ok(cleaned);
      }
      _log.w('Cleanup dropped content; retrying with preservation prompt');
      return _retryCleanupForPreservation(rawTranscript, cleaned.cleanedText);
    }

    _log.w('Cleanup parse failed; retrying with stricter prompt');
    final retry = await runner.generate(
      cleanupTranscriptRetryPrompt(rawTranscript, rawResponse),
      temperature: kRecordLogTemperature,
    );
    switch (retry) {
      case Ok(:final value):
        cleaned = parseCleanupTranscript(value);
      case Err(:final error):
        return Err(error);
    }
    if (cleaned == null) return const Ok(null);
    if (_isCleanupContentPreserved(rawTranscript, cleaned.cleanedText)) {
      return Ok(cleaned);
    }
    _log.w('Cleanup retry dropped content; falling back to raw transcript');
    return const Ok(null);
  }

  Future<Result<ParsedCleanupTranscript?, LlmError>>
  _retryCleanupForPreservation(
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
    ParsedCleanupTranscript? cleaned;
    switch (retry) {
      case Ok(:final value):
        cleaned = parseCleanupTranscript(value);
      case Err(:final error):
        return Err(error);
    }
    if (cleaned == null) return const Ok(null);
    if (_isCleanupContentPreserved(rawTranscript, cleaned.cleanedText)) {
      return Ok(cleaned);
    }
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

  /// Dedicated title pass over the cleaned text. Preference order:
  ///   1. Dedicated Gemma title call (one stricter retry on parse failure).
  ///   2. Legacy in-cleanup title (older prompts or future model that still
  ///      embeds it — kept so cached responses don't regress).
  ///   3. Deterministic [synthesizeFallbackTitle] over the cleaned text.
  ///   4. Null when the cleaned text is itself empty.
  Future<TitleAndFlowerType> _resolveTitle({
    required String cleanedText,
    required String? legacyTitle,
  }) async {
    final trimmed = cleanedText.trim();
    if (trimmed.isEmpty) {
      return TitleAndFlowerType(
        title: _sanitizeOrFallback(legacyTitle, cleanedText),
        flowerType: 'sakura',
      );
    }
    final titleResult = await runner.generate(
      generateLogTitlePrompt(trimmed),
      temperature: kRecordLogTemperature,
    );
    String? response;
    switch (titleResult) {
      case Ok(:final value):
        response = value;
        _log.i('Title response chars=${value.length}');
      case Err(:final error):
        _log.w('Title generation failed; falling back', error: error);
        return TitleAndFlowerType(
          title: _sanitizeOrFallback(legacyTitle, cleanedText),
          flowerType: 'sakura',
        );
    }

    var result = parseTitleResponse(response);
    if (result.title != null) return result;

    _log.w('Title parse failed; retrying with stricter prompt');
    final retry = await runner.generate(
      generateLogTitleRetryPrompt(trimmed, response),
      temperature: kRecordLogTemperature,
    );
    switch (retry) {
      case Ok(:final value):
        result = parseTitleResponse(value);
      case Err(:final error):
        _log.w('Title retry failed; falling back', error: error);
        return TitleAndFlowerType(
          title: _sanitizeOrFallback(legacyTitle, cleanedText),
          flowerType: 'sakura',
        );
    }
    if (result.title != null) return result;

    _log.w('Title retry parse failed; falling back');
    return TitleAndFlowerType(
      title: _sanitizeOrFallback(legacyTitle, cleanedText),
      flowerType: result.flowerType ?? 'sakura',
    );
  }

  String? _sanitizeOrFallback(String? legacyTitle, String cleanedText) {
    final legacy = legacyTitle?.trim();
    if (legacy != null && legacy.isNotEmpty) return legacy;
    return synthesizeFallbackTitle(cleanedText);
  }

  /// Fourth refine stage. Best-effort: any failure is logged and swallowed
  /// so chip-less logs still complete refine and reach embed.
  Future<void> _generateAndPersistSuggestions({
    required String logId,
    required String cleanedText,
  }) async {
    final repo = suggestions;
    if (repo == null) return;
    final trimmed = cleanedText.trim();
    if (trimmed.isEmpty) return;

    final first = await runner.generate(
      generateSuggestionsPrompt(trimmed),
      temperature: kRecordLogTemperature,
    );
    String response;
    switch (first) {
      case Ok(:final value):
        response = value;
        _log.i('Suggestion response chars=${value.length}');
      case Err(:final error):
        _log.w('Suggestion stage failed; skipping chips', error: error);
        return;
    }

    var parsed = parseSuggestionsResponse(response);
    if (parsed == null) {
      _log.w('Suggestion parse failed; retrying with stricter prompt');
      final retry = await runner.generate(
        generateSuggestionsRetryPrompt(trimmed, response),
        temperature: kRecordLogTemperature,
      );
      switch (retry) {
        case Ok(:final value):
          parsed = parseSuggestionsResponse(value);
        case Err(:final error):
          _log.w('Suggestion retry failed; skipping chips', error: error);
          return;
      }
    }
    if (parsed == null || parsed.isEmpty) {
      _log.w('Suggestion retry produced nothing usable; skipping chips');
      return;
    }

    final candidates = parsed
        .map(
          (s) => PromptSuggestionCandidate(
            chipText: s.chipText,
            question: s.question,
          ),
        )
        .toList(growable: false);
    final result = await repo.replaceForLog(
      logId: logId,
      candidates: candidates,
    );
    switch (result) {
      case Ok(:final value):
        _log.i('Stored ${value.length} prompt suggestions');
      case Err(:final error):
        _log.w('Failed to persist suggestions; skipping chips', error: error);
    }
  }
}

/// Deterministic fallback used when Gemma omits the title key. Keeps old
/// backups/tests and occasional malformed model responses from leaving the home
/// list as an empty title.
String? synthesizeFallbackTitle(String text) {
  final normalized = text
      .replaceAll(RegExp(r'[#*_`>\-]+'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (normalized.isEmpty) return null;

  final firstSentence = RegExp(
    r'(.{1,120}?)(?:[.!?]|$)',
  ).firstMatch(normalized);
  final source = (firstSentence?.group(1) ?? normalized).trim();
  final words = RegExp(r"[A-Za-z0-9]+(?:['’-][A-Za-z0-9]+)?")
      .allMatches(source)
      .map((m) => m.group(0)!)
      .where(
        (w) =>
            w.length > 1 && !_fallbackTitleDropWords.contains(w.toLowerCase()),
      )
      .take(10)
      .toList(growable: false);
  final selected = words.isEmpty
      ? RegExp(r"[A-Za-z0-9]+(?:['’-][A-Za-z0-9]+)?")
            .allMatches(source)
            .map((m) => m.group(0)!)
            .take(10)
            .toList(growable: false)
      : words;
  if (selected.isEmpty) return null;
  return selected.join(' ');
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

const Set<String> _fallbackTitleDropWords = {
  'i',
  'me',
  'my',
  'we',
  'our',
  'you',
  'your',
  'today',
  'just',
  'need',
  'needs',
  'about',
  'talked',
  'talk',
  'call',
  'called',
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
};

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
