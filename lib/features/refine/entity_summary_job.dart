import '../../core/app_error.dart';
import '../../core/db/job_state.dart';
import '../../core/db/repositories/canonical_entity_repository.dart';
import '../../core/db/repositories/entity_mention_repository.dart';
import '../../core/db/repositories/entity_summary_repository.dart';
import '../../core/db/repositories/voice_log_repository.dart';
import '../../core/logger.dart';
import '../../core/result.dart';
import '../../core/worker/job_handler.dart';
import 'entity_summary_prompt.dart';
import 'llm_runner.dart';

/// Background handler for [JobType.entitySummary].
///
/// **Polymorphic queue id.** The [JobContext.logId] passed in here actually
/// holds a canonical-entity id — the queue keys every job on a single
/// string column and we reuse it as a target id for non-log work. The
/// rest of the pipeline (refine, embed, canonicalize…) still treats it as
/// a log id. Keep this asymmetry localized to this handler.
///
/// **Two generation paths:**
///   * **Full rebuild** — runs on first generation and every
///     [kFullRebuildEvery] mentions to fight incremental drift. Loads
///     up to [recentLogLimit] freshest logs, asks Gemma to derive both
///     the rendered summary and the structured facts from scratch.
///   * **Incremental merge** — runs in between. Loads only the logs
///     newer than the persisted `lastMergedLogId` and asks Gemma to
///     fold them into the existing facts in place.
class EntitySummaryJobHandler implements JobHandler {
  EntitySummaryJobHandler({
    required this.runner,
    required this.canonicals,
    required this.mentions,
    required this.voiceLogs,
    required this.summaries,
    this.recentLogLimit = 6,
    this.snippetCharBudget = 600,
    this.incrementalSnippetCharBudget = 360,
    this.modelVersion = 'gemma-3-1b-it',
  });

  final LlmRunner runner;
  final CanonicalEntityRepository canonicals;
  final EntityMentionRepository mentions;
  final VoiceLogRepository voiceLogs;
  final EntitySummaryRepository summaries;
  final int recentLogLimit;
  final int snippetCharBudget;
  final int incrementalSnippetCharBudget;
  final String modelVersion;

  final _log = Logger('entity_summary_job');

  @override
  JobType get type => JobType.entitySummary;

  @override
  Future<Result<JobOutcome, AppError>> handle(JobContext ctx) async {
    final entityId = ctx.logId;
    final entity = await canonicals.find(entityId);
    if (entity == null) {
      _log.w('Entity vanished before summary could run: $entityId');
      return const Ok(JobFailedPermanently('entity not found'));
    }

    final needsWork = await summaries.needsRegeneration(
      entityId: entityId,
      currentMentionCount: entity.mentionCount,
    );
    if (!needsWork) {
      _log.i('Summary already fresh for $entityId; skipping');
      return const Ok(JobSucceeded());
    }

    final existing = await summaries.find(entityId);
    final mode = _decideMode(entity.mentionCount, existing);
    _log.i(
      'entity_summary mode=${mode.name} '
      'entity=${entity.displayName} '
      'mentionCount=${entity.mentionCount}',
    );

    final result = switch (mode) {
      _Mode.full => await _runFullRebuild(entity),
      _Mode.incremental => await _runIncremental(entity, existing!),
    };
    switch (result) {
      case Ok():
        _log.i('Stored entity summary for ${entity.displayName} ($entityId)');
        return const Ok(JobSucceeded());
      case Err(:final error):
        _log.w('Failed to persist entity summary', error: error);
        return Err<JobOutcome, AppError>(error);
    }
  }

  _Mode _decideMode(int mentionCount, EntitySummaryView? existing) {
    if (existing == null) return _Mode.full;
    final facts = existing.structuredFacts;
    if (facts == null || facts.isEmpty) return _Mode.full;
    final lastFullCount = facts.lastFullRebuildMentionCount;
    if (lastFullCount == null) return _Mode.full;
    if (mentionCount - lastFullCount >= kFullRebuildEvery) return _Mode.full;
    return _Mode.incremental;
  }

  Future<Result<EntitySummaryView, EntitySummaryError>> _runFullRebuild(
    CanonicalEntityView entity,
  ) async {
    final logIds = await mentions.logIdsForEntity(
      entity.id,
      limit: recentLogLimit,
    );
    final loaded = await _loadSnippets(logIds, snippetCharBudget);

    final input = EntitySummaryPromptInput(
      displayName: entity.displayName,
      type: entity.type,
      mentionCount: entity.mentionCount,
      recentLogTitles: loaded.titles,
      recentLogSnippets: loaded.snippets,
    );

    final generation = await _generateOrFallback(
      buildPrompt: () => entitySummaryFullPrompt(input),
      buildRetry: (prev) =>
          entitySummaryRetryPrompt(input: input, previousResponse: prev),
      input: input,
    );

    final newestLogId = logIds.isEmpty ? null : logIds.first;
    final now = DateTime.now().millisecondsSinceEpoch;
    final mergedFacts = generation.facts.copyWith(
      lastMergedLogId: newestLogId,
      lastFullRebuildAt: now,
      lastFullRebuildMentionCount: entity.mentionCount,
    );

    return summaries.upsert(
      entityId: entity.id,
      summaryText: generation.summary,
      mentionCount: entity.mentionCount,
      modelVersion: modelVersion,
      structuredFacts: mergedFacts,
    );
  }

  Future<Result<EntitySummaryView, EntitySummaryError>> _runIncremental(
    CanonicalEntityView entity,
    EntitySummaryView existing,
  ) async {
    final facts = existing.structuredFacts!;
    final allLogIds = await mentions.logIdsForEntity(
      entity.id,
      limit: recentLogLimit,
    );
    // logIds are newest-first; "new" = everything before lastMergedLogId.
    final newIds = _logsSince(allLogIds, facts.lastMergedLogId);
    if (newIds.isEmpty) {
      _log.i(
        'Incremental run for ${entity.displayName}: no new logs since '
        '${facts.lastMergedLogId}; advancing snapshot only',
      );
      // Mention count grew but no new logs surfaced (e.g. multiple
      // mentions in the same log). Persist the new snapshot so the
      // staleness check stops firing on every refine.
      return summaries.upsert(
        entityId: entity.id,
        summaryText: existing.summaryText,
        mentionCount: entity.mentionCount,
        modelVersion: modelVersion,
        structuredFacts: facts,
      );
    }

    final loaded = await _loadSnippets(newIds, incrementalSnippetCharBudget);
    final input = EntitySummaryPromptInput(
      displayName: entity.displayName,
      type: entity.type,
      mentionCount: entity.mentionCount,
      recentLogTitles: loaded.titles,
      recentLogSnippets: loaded.snippets,
    );

    final generation = await _generateOrFallback(
      buildPrompt: () => entitySummaryIncrementalPrompt(
        input: input,
        currentFacts: facts,
        newLogTitles: loaded.titles,
        newLogSnippets: loaded.snippets,
      ),
      buildRetry: (prev) =>
          entitySummaryRetryPrompt(input: input, previousResponse: prev),
      input: input,
      // On incremental fallback, keep the previous summary instead of a
      // generic "mentioned in N logs" blurb — the existing one is
      // strictly more informative than the deterministic fallback.
      fallbackSummary: existing.summaryText,
      fallbackFacts: facts,
    );

    final newestLogId = newIds.first;
    final mergedFacts = generation.facts.copyWith(
      lastMergedLogId: newestLogId,
      lastFullRebuildAt: facts.lastFullRebuildAt,
      lastFullRebuildMentionCount: facts.lastFullRebuildMentionCount,
    );

    return summaries.upsert(
      entityId: entity.id,
      summaryText: generation.summary,
      mentionCount: entity.mentionCount,
      modelVersion: modelVersion,
      structuredFacts: mergedFacts,
    );
  }

  Future<_LoadedSnippets> _loadSnippets(
    List<String> logIds,
    int charBudget,
  ) async {
    final titles = <String>[];
    final snippets = <String>[];
    var snippetChars = 0;
    for (final id in logIds) {
      final log = await voiceLogs.find(id);
      if (log == null) continue;
      final title = log.title?.trim();
      if (title != null && title.isNotEmpty) titles.add(title);
      final body = (log.cleanedText?.trim().isNotEmpty ?? false)
          ? log.cleanedText!.trim()
          : log.rawTranscript.trim();
      if (body.isEmpty) continue;
      final remaining = charBudget - snippetChars;
      if (remaining <= 80) break;
      final slice = body.length > remaining
          ? '${body.substring(0, remaining - 1)}…'
          : body;
      snippets.add(slice);
      snippetChars += slice.length;
    }
    return _LoadedSnippets(titles: titles, snippets: snippets);
  }

  /// Generate via Gemma with one stricter retry on parse failure. Any
  /// LLM error or empty parse falls back to a deterministic blurb so the
  /// entity page always has something to show.
  Future<EntitySummaryGeneration> _generateOrFallback({
    required String Function() buildPrompt,
    required String Function(String previous) buildRetry,
    required EntitySummaryPromptInput input,
    String? fallbackSummary,
    EntityStructuredFacts? fallbackFacts,
  }) async {
    EntitySummaryGeneration fallback() {
      return EntitySummaryGeneration(
        summary: fallbackSummary ?? synthesizeFallbackEntitySummary(input),
        facts: fallbackFacts ?? EntityStructuredFacts.empty,
      );
    }

    // Match Ask's non-greedy sampling — narrative output loops on a 1B
    // model with the default topK=1.
    final first = await runner.generate(
      buildPrompt(),
      temperature: 1.0,
      topK: 64,
    );
    String response;
    switch (first) {
      case Ok(:final value):
        response = value;
      case Err(:final error):
        _log.w('Entity summary LLM call failed; using fallback', error: error);
        return fallback();
    }

    var parsed = parseEntitySummaryGeneration(response);
    if (parsed != null) return parsed;

    _log.w('Entity summary parse failed; retrying with stricter prompt');
    final retry = await runner.generate(
      buildRetry(response),
      temperature: 1.0,
      topK: 64,
    );
    switch (retry) {
      case Ok(:final value):
        parsed = parseEntitySummaryGeneration(value);
      case Err(:final error):
        _log.w('Entity summary retry failed; using fallback', error: error);
        return fallback();
    }
    return parsed ?? fallback();
  }
}

/// Returns the prefix of [logIds] (newest-first) up to but not including
/// [marker]. If [marker] is null or absent, returns the full list.
List<String> _logsSince(List<String> logIds, String? marker) {
  if (marker == null) return List.unmodifiable(logIds);
  final idx = logIds.indexOf(marker);
  if (idx < 0) return List.unmodifiable(logIds);
  return List.unmodifiable(logIds.take(idx));
}

class _LoadedSnippets {
  const _LoadedSnippets({required this.titles, required this.snippets});
  final List<String> titles;
  final List<String> snippets;
}

enum _Mode { full, incremental }
