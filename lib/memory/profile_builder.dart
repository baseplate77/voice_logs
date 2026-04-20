import '../core/errors.dart';
import '../core/logger.dart';
import '../core/result.dart';
import '../llm/llm_runner.dart';
import 'memory_repository.dart';
import 'models/memory.dart';
import 'models/profile_summary.dart';
import 'prompts/profile_build.dart';

/// How many recent decisions feed the "recent decisions" section.
const int kProfileRecentDecisionsLimit = 5;

/// Confidence floor for facts / goals entering the summary. Low-
/// confidence items make the blurb noisy.
const double kProfileMinConfidence = 0.6;

/// Temperature for the rebuild call. Low so small memory changes
/// don't jitter the whole summary.
const double kProfileBuildTemperature = 0.2;

/// Hard cap on the stored summary in characters. Roughly 300 tokens ≈
/// 1200-1500 chars for Gemma's SP tokenizer; we err on the side of
/// truncation rather than let the prompt bloat.
const int kProfileSummaryMaxChars = 1500;

/// Maintain the always-on "about me" profile summary.
///
/// The single-row cache in `profile_summaries` is the source of truth;
/// this class wraps the rebuild policy + call to Gemma. Stale-flag
/// flow:
///   - [markStale] flips `is_stale` to 1 (called from the ingestion
///     coordinator whenever consolidation structurally changes the
///     memory set).
///   - [current] returns the cached summary, triggering a rebuild on
///     the fly if stale. This keeps the always-on profile lazy —
///     background jobs aren't required for the feature to work.
///   - [rebuild] is the explicit "do it now" path, also used by
///     [ProfileRefreshJob] for batch refreshes while the device is
///     idle.
class ProfileBuilder {
  ProfileBuilder({
    required this.repository,
    required this.runner,
    AppLogger? logger,
    DateTime Function()? clock,
  })  : _logger = logger ?? AppLogger(),
        _now = clock ?? DateTime.now;

  final MemoryRepository repository;
  final LlmRunner runner;
  final AppLogger _logger;
  final DateTime Function() _now;

  /// Read the cache, rebuilding lazily if the stale flag is set.
  Future<Result<ProfileSummary, AppError>> current() async {
    final cacheR = await repository.loadProfileSummary();
    if (cacheR.isErr) {
      return Err<ProfileSummary, AppError>(cacheR.errOrNull!);
    }
    final cache = cacheR.okOrNull!;
    if (!cache.isStale) {
      return Ok<ProfileSummary, AppError>(
        ProfileSummary(
          summary: cache.summary,
          updatedAt: cache.updatedAt,
          sourceMemoryIds: cache.sourceMemoryIds,
          isStale: false,
        ),
      );
    }
    return rebuild();
  }

  /// Mark the cache stale — the next `current()` call will rebuild.
  /// Idempotent.
  Future<Result<void, AppError>> markStale() =>
      repository.markProfileStale();

  /// Rebuild the summary synchronously. Pulls the top active facts +
  /// open goals + recent decisions, formats them for the prompt, asks
  /// Gemma for a ~200-word blurb, and persists it.
  Future<Result<ProfileSummary, AppError>> rebuild() async {
    try {
      final facts = await _loadTop(
        kind: MemoryKind.fact,
        limit: 25,
      );
      final goals = await _loadTop(
        kind: MemoryKind.goal,
        limit: 15,
      );
      final decisions = await _loadTop(
        kind: MemoryKind.decision,
        limit: kProfileRecentDecisionsLimit,
      );

      // No memories yet — persist an empty blurb so the query path
      // doesn't keep retrying a rebuild.
      if (facts.isEmpty && goals.isEmpty && decisions.isEmpty) {
        final saveR = await repository.saveProfileSummary(
          summary: '',
          sourceMemoryIds: const <MemoryId>[],
          updatedAt: _now(),
        );
        if (saveR.isErr) {
          return Err<ProfileSummary, AppError>(saveR.errOrNull!);
        }
        return Ok<ProfileSummary, AppError>(ProfileSummary.empty);
      }

      // Filter goals to open/in-progress — done and abandoned don't
      // belong in the "about me" section.
      final openGoals = goals.whereType<GoalMemory>().where(
            (g) =>
                g.state == GoalState.open ||
                g.state == GoalState.inProgress,
          );

      final prompt = profileBuildTemplate.render(<String, String>{
        'facts': _formatFacts(facts.whereType<FactMemory>()),
        'goals': _formatGoals(openGoals),
        'decisions':
            _formatDecisions(decisions.whereType<DecisionMemory>()),
      });
      final r = await runner.generateSync(
        prompt,
        temperatureOverride: kProfileBuildTemperature,
      );
      if (r.isErr) {
        return Err<ProfileSummary, AppError>(r.errOrNull!);
      }
      var summary = r.okOrNull!.trim();
      if (summary.length > kProfileSummaryMaxChars) {
        // Hard truncate on word boundary so we don't lop off mid-
        // sentence and leave a dangling "The ".
        summary = summary.substring(0, kProfileSummaryMaxChars);
        final lastSpace = summary.lastIndexOf(' ');
        if (lastSpace > 0) summary = summary.substring(0, lastSpace);
        summary = '$summary…';
      }

      final sourceIds = <MemoryId>[
        ...facts.map((m) => m.id),
        ...openGoals.map((m) => m.id),
        ...decisions.map((m) => m.id),
      ];

      final now = _now();
      final saveR = await repository.saveProfileSummary(
        summary: summary,
        sourceMemoryIds: sourceIds,
        updatedAt: now,
      );
      if (saveR.isErr) {
        return Err<ProfileSummary, AppError>(saveR.errOrNull!);
      }
      return Ok<ProfileSummary, AppError>(
        ProfileSummary(
          summary: summary,
          updatedAt: now,
          sourceMemoryIds: sourceIds,
          isStale: false,
        ),
      );
    } on Object catch (e, st) {
      _logger.error('profile rebuild failed',
          error: e, stackTrace: st);
      return Err<ProfileSummary, AppError>(
        UnknownError('profile rebuild failed',
            cause: e, stackTrace: st),
      );
    }
  }

  Future<List<Memory>> _loadTop({
    required MemoryKind kind,
    required int limit,
  }) async {
    final r = await repository.list(
      kind: kind,
      limit: limit,
      minConfidence: kProfileMinConfidence,
    );
    if (r.isErr) return const <Memory>[];
    return r.okOrNull!;
  }

  static String _formatFacts(Iterable<FactMemory> facts) {
    if (facts.isEmpty) return '(none)';
    return facts.map((f) => '- ${f.content}').join('\n');
  }

  static String _formatGoals(Iterable<GoalMemory> goals) {
    if (goals.isEmpty) return '(none)';
    return goals.map((g) {
      final state = switch (g.state) {
        GoalState.open => 'open',
        GoalState.inProgress => 'in progress',
        GoalState.done => 'done',
        GoalState.abandoned => 'abandoned',
      };
      final due = g.dueAt == null ? '' : ' (due ${_ymd(g.dueAt!)})';
      return '- [$state$due] ${g.content}';
    }).join('\n');
  }

  static String _formatDecisions(Iterable<DecisionMemory> decisions) {
    if (decisions.isEmpty) return '(none)';
    // Sort newest-first by occurred date so the narrative flows chrono.
    final sorted = decisions.toList(growable: false)
      ..sort((a, b) => b.occurredAt.compareTo(a.occurredAt));
    return sorted
        .map((d) => '- ${_ymd(d.occurredAt)}: ${d.content}')
        .join('\n');
  }

  static String _ymd(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
}
