import '../../core/app_error.dart';
import '../../core/db/job_state.dart';
import '../../core/db/repositories/entity_mention_repository.dart';
import '../../core/db/repositories/voice_log_repository.dart';
import '../../core/logger.dart';
import '../../core/result.dart';
import '../../core/worker/job_handler.dart';
import '../../core/worker/job_queue.dart';
import 'llm_chunker.dart';
import 'llm_runner.dart';
import 'offset_recovery.dart';
import 'prompt_templates.dart';
import 'response_parser.dart';

String _elapsed(Stopwatch watch) {
  final elapsed = watch.elapsed;
  if (elapsed.inSeconds >= 1) {
    return '${elapsed.inSeconds}.${(elapsed.inMilliseconds % 1000).toString().padLeft(3, '0')}s';
  }
  return '${elapsed.inMilliseconds}ms';
}

int _wordCount(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return 0;
  return trimmed.split(RegExp(r'\s+')).length;
}

/// Refine handler that drives the real Gemma pipeline. Replaces
/// [DummyRefiner] from Phase 2. Enqueues the downstream embed job on
/// success, same as the dummy did, so the rest of the pipeline doesn't
/// care which refiner ran.
class GemmaRefiner implements JobHandler {
  GemmaRefiner({
    required this.runner,
    required this.voiceLogs,
    required this.mentions,
    required this.queue,
    this.chunkTargetWords = 450,
    this.chunkOverlapWords = 50,
  });

  final LlmRunner runner;
  final VoiceLogRepository voiceLogs;
  final EntityMentionRepository mentions;
  final JobQueue queue;
  final int chunkTargetWords;
  final int chunkOverlapWords;

  final _log = Logger('gemma_refiner');

  @override
  JobType get type => JobType.refine;

  @override
  Future<Result<JobOutcome, AppError>> handle(JobContext ctx) async {
    final total = Stopwatch()..start();
    _log.i(
      'Refine start job=${ctx.jobId} log=${ctx.logId} '
      'attempt=${ctx.attempts}',
    );

    final logWatch = Stopwatch()..start();
    final log = await voiceLogs.find(ctx.logId);
    _log.d('Loaded source log in ${_elapsed(logWatch)}');
    if (log == null) {
      _log.w('Refine aborted: log not found after ${_elapsed(total)}');
      return const Ok(JobFailedPermanently('log not found'));
    }

    final rawTranscript = log.rawTranscript;
    _log.i(
      'Refine input log=${ctx.logId}: chars=${rawTranscript.length}, '
      'words=${_wordCount(rawTranscript)}',
    );
    if (rawTranscript.trim().isEmpty) {
      await voiceLogs.markRefined(id: ctx.logId, cleanedText: rawTranscript);
      await queue.enqueue(logId: ctx.logId, type: JobType.embed);
      _log.i('Refine complete empty transcript in ${_elapsed(total)}');
      return const Ok(JobSucceeded());
    }

    final loadWatch = Stopwatch()..start();
    final loaded = await runner.load();
    _log.i('Gemma load/ensure-ready took ${_elapsed(loadWatch)}');
    switch (loaded) {
      case Ok():
        break;
      case Err(:final error):
        _log.w(
          'Refine failed during Gemma load after ${_elapsed(total)}',
          error: error,
        );
        return Err(error);
    }

    final chunks = splitForLlmRefine(
      rawTranscript,
      targetWords: chunkTargetWords,
      overlapWords: chunkOverlapWords,
    );
    _log.i(
      'Split refine input into ${chunks.length} chunk(s): '
      'targetWords=$chunkTargetWords overlapWords=$chunkOverlapWords',
    );

    final refinedChunks = <RefinedTextChunk>[];
    for (final chunk in chunks) {
      final chunkWatch = Stopwatch()..start();
      final refined = await _refineChunk(chunk, total);
      switch (refined) {
        case Ok(:final value):
          refinedChunks.add(value);
          _log.i(
            'Chunk ${chunk.index + 1}/${chunks.length} refined in '
            '${_elapsed(chunkWatch)}',
          );
        case Err(:final error):
          return Err(error);
      }
    }

    final stitchWatch = Stopwatch()..start();
    final stitched = stitchRefinedChunks(
      refinedChunks,
      maxOverlapWords: chunkOverlapWords + 10,
      minOverlapWordsToDrop: (chunkOverlapWords ~/ 2).clamp(1, 5),
    );
    _log.i(
      'Stitched ${refinedChunks.length} chunk(s) in ${_elapsed(stitchWatch)}: '
      'cleanedChars=${stitched.cleanedText.length}, '
      'entities=${stitched.mentions.length}',
    );

    final persistWatch = Stopwatch()..start();
    final markRes = await voiceLogs.markRefined(
      id: ctx.logId,
      cleanedText: stitched.cleanedText,
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
      mentions: stitched.mentions,
    );
    switch (mentionRes) {
      case Ok():
        break;
      case Err(:final error):
        _log.w('Refine failed while saving mentions', error: error);
        return Err(error);
    }

    await queue.enqueue(logId: ctx.logId, type: JobType.embed);
    _log.i(
      'Persist/enqueue took ${_elapsed(persistWatch)}; '
      'refine complete in ${_elapsed(total)}',
    );
    return const Ok(JobSucceeded());
  }

  Future<Result<RefinedTextChunk, AppError>> _refineChunk(
    LlmTextChunk chunk,
    Stopwatch total,
  ) async {
    _log.i(
      'Refining chunk ${chunk.index}: chars=${chunk.text.length}, '
      'words=${_wordCount(chunk.text)}',
    );

    final prompt = recordLogPrompt(chunk.text);
    _log.i('Chunk ${chunk.index} first prompt chars=${prompt.length}');
    final firstWatch = Stopwatch()..start();
    final firstRes = await runner.generate(prompt);
    _log.i(
      'Chunk ${chunk.index} first Gemma generation took '
      '${_elapsed(firstWatch)}',
    );
    String rawResponse;
    switch (firstRes) {
      case Ok(:final value):
        rawResponse = value;
        _log.i('Chunk ${chunk.index} first response chars=${value.length}');
      case Err(:final error):
        _log.w(
          'Refine failed during chunk ${chunk.index} first generation '
          'after ${_elapsed(total)}',
          error: error,
        );
        return Err(error);
    }

    final parseWatch = Stopwatch()..start();
    var parsed = parseRecordLog(rawResponse);
    _log.d('Chunk ${chunk.index} first parse took ${_elapsed(parseWatch)}');
    if (parsed == null) {
      _log.w(
        'Chunk ${chunk.index} parse failed after response '
        'chars=${rawResponse.length}; retrying',
      );
      final retryPrompt = recordLogRetryPrompt(chunk.text, rawResponse);
      _log.i('Chunk ${chunk.index} retry prompt chars=${retryPrompt.length}');
      final retryWatch = Stopwatch()..start();
      final retry = await runner.generate(retryPrompt);
      _log.i(
        'Chunk ${chunk.index} retry Gemma generation took '
        '${_elapsed(retryWatch)}',
      );
      switch (retry) {
        case Ok(:final value):
          _log.i('Chunk ${chunk.index} retry response chars=${value.length}');
          final retryParseWatch = Stopwatch()..start();
          parsed = parseRecordLog(value);
          _log.d(
            'Chunk ${chunk.index} retry parse took '
            '${_elapsed(retryParseWatch)}',
          );
        case Err(:final error):
          _log.w(
            'Refine failed during chunk ${chunk.index} retry generation '
            'after ${_elapsed(total)}',
            error: error,
          );
          return Err(error);
      }
    }

    if (parsed == null) {
      _log.w(
        'Chunk ${chunk.index} retry also failed; using raw chunk text '
        'for this chunk',
      );
      return Ok(
        RefinedTextChunk(
          index: chunk.index,
          cleanedText: chunk.text,
          mentions: const [],
        ),
      );
    }

    final offsetWatch = Stopwatch()..start();
    final located = recoverOffsets(
      cleanedText: parsed.cleanedText,
      mentions: parsed.mentions,
    );
    _log.i(
      'Chunk ${chunk.index} parsed: cleanedChars=${parsed.cleanedText.length}, '
      'entities=${parsed.mentions.length}, located=${located.length}, '
      'offsetTime=${_elapsed(offsetWatch)}',
    );
    return Ok(
      RefinedTextChunk(
        index: chunk.index,
        cleanedText: parsed.cleanedText,
        mentions: located,
      ),
    );
  }
}
