import 'dart:typed_data';

import '../../core/errors.dart';
import '../../core/logger.dart';
import '../../core/result.dart';
import '../../embed/embedder.dart';
import '../../llm/llm_runner.dart';
import '../memory_repository.dart';
import '../memory_vector_index.dart';
import '../models/memory.dart';
import '../profile_builder.dart';
import '../prompts/consolidation_judge.dart';

/// Background sweep over the entire memory store. Catches duplicates
/// or supersedences that escaped the on-ingest consolidator — e.g.
/// when two candidates land in the same batch that inadvertently
/// duplicate each other, or when near-duplicate phrasings just missed
/// the cosine prefilter on ingest.
///
/// Runs weekly via the Phase 7 [BackgroundScheduler]. Idempotent — the
/// judge's verdicts are deterministic at low temperature, and the
/// merge/supersede ops don't introduce new memories.
class MemoryConsolidationJob {
  MemoryConsolidationJob({
    required this.repository,
    required this.embedder,
    required this.vectorIndex,
    required this.judgeRunner,
    required this.profileBuilder,
    AppLogger? logger,
    DateTime Function()? clock,
  })  : _logger = logger ?? AppLogger(),
        _now = clock ?? DateTime.now;

  final MemoryRepository repository;
  final Embedder embedder;
  final MemoryVectorIndex vectorIndex;
  final LlmRunner judgeRunner;
  final ProfileBuilder profileBuilder;
  final AppLogger _logger;
  final DateTime Function() _now;

  /// Process at most this many memories per run. Caps the worst-case
  /// LLM spend on a big corpus; anything beyond rolls into next week.
  static const int kMaxMemoriesPerRun = 200;

  /// Run the sweep. Returns the count of merges + supersedes applied.
  Future<Result<MemoryConsolidationJobOutput, AppError>> run() async {
    try {
      final listR = await repository.list(limit: kMaxMemoriesPerRun);
      if (listR.isErr) {
        return Err<MemoryConsolidationJobOutput, AppError>(listR.errOrNull!);
      }
      final memories = listR.okOrNull!;
      if (memories.length < 2) {
        return const Ok<MemoryConsolidationJobOutput, AppError>(
          MemoryConsolidationJobOutput(merges: 0, supersedes: 0),
        );
      }
      var merges = 0;
      var supersedes = 0;
      final visited = <String>{};
      final reembedCache = <String, Float32List>{};

      for (final current in memories) {
        if (visited.contains(current.id.raw)) continue;
        if (current.status != MemoryStatus.active) continue;
        final query = await _embedding(current, reembedCache);
        if (query == null) continue;
        final neighbours =
            vectorIndex.nearest(query, 5);
        for (final n in neighbours) {
          if (n.memoryId == current.id.raw) continue;
          if (visited.contains(n.memoryId)) continue;
          final sim = 1.0 - n.score;
          if (sim < kConsolidationMergeThreshold) break;
          final otherR = await repository.get(MemoryId(n.memoryId));
          if (otherR.isErr) continue;
          final other = otherR.okOrNull;
          if (other == null || other.status != MemoryStatus.active) {
            continue;
          }
          if (other.kind != current.kind) continue;
          final verdict = await _askJudge(current: current, other: other);
          switch (verdict) {
            case _SweepVerdict.duplicate:
              final superR = await repository.supersede(
                old: other.id,
                replacement: current.id,
                now: _now(),
              );
              if (superR.isOk) {
                merges++;
                visited.add(other.id.raw);
              }
            case _SweepVerdict.contradiction:
              // Newer by updatedAt wins — in a weekly sweep we already
              // have both rows, so "newer" is preferable as the
              // survivor. Ties break toward `current`.
              final (winner, loser) =
                  other.updatedAt.isAfter(current.updatedAt)
                      ? (other, current)
                      : (current, other);
              final superR = await repository.supersede(
                old: loser.id,
                replacement: winner.id,
                now: _now(),
              );
              if (superR.isOk) {
                supersedes++;
                visited.add(loser.id.raw);
                if (loser.id == current.id) {
                  // The current row just got retired — stop scanning
                  // its neighbours.
                  visited.add(current.id.raw);
                  break;
                }
              }
            case _SweepVerdict.unrelated:
            case _SweepVerdict.unknown:
              continue;
          }
        }
      }

      if (merges + supersedes > 0) {
        final staleR = await profileBuilder.markStale();
        if (staleR.isErr) {
          _logger.warn(
            'MemoryConsolidationJob: markStale failed: '
            '${staleR.errOrNull}',
          );
        }
      }
      return Ok<MemoryConsolidationJobOutput, AppError>(
        MemoryConsolidationJobOutput(merges: merges, supersedes: supersedes),
      );
    } on Object catch (e, st) {
      _logger.error('MemoryConsolidationJob run failed',
          error: e, stackTrace: st);
      return Err<MemoryConsolidationJobOutput, AppError>(
        UnknownError('memory consolidation sweep failed',
            cause: e, stackTrace: st),
      );
    }
  }

  Future<Float32List?> _embedding(
    Memory m,
    Map<String, Float32List> cache,
  ) async {
    final cached = cache[m.id.raw];
    if (cached != null) return cached;
    final r = await embedder.embedPassages(<String>['${m.title}\n\n${m.content}']);
    if (r.isErr) return null;
    final vectors = r.okOrNull!;
    if (vectors.isEmpty) return null;
    cache[m.id.raw] = vectors.first;
    return vectors.first;
  }

  Future<_SweepVerdict> _askJudge({
    required Memory current,
    required Memory other,
  }) async {
    final prompt = consolidationJudgeTemplate.render(<String, String>{
      'existing_kind': other.kind.name,
      'existing_title': other.title,
      'existing_content': other.content,
      'new_kind': current.kind.name,
      'new_title': current.title,
      'new_content': current.content,
    });
    final r = await judgeRunner.generateSync(prompt);
    if (r.isErr) return _SweepVerdict.unknown;
    final raw = r.okOrNull!.toLowerCase();
    if (raw.contains('"duplicate"')) return _SweepVerdict.duplicate;
    if (raw.contains('"contradiction"')) return _SweepVerdict.contradiction;
    if (raw.contains('"unrelated"')) return _SweepVerdict.unrelated;
    return _SweepVerdict.unknown;
  }
}

/// How the sweep resolved one memory pair.
enum _SweepVerdict { duplicate, contradiction, unrelated, unknown }

/// Bundled counters so callers / tests can assert sweep outcomes.
final class MemoryConsolidationJobOutput {
  const MemoryConsolidationJobOutput({
    required this.merges,
    required this.supersedes,
  });

  final int merges;
  final int supersedes;

  @override
  String toString() =>
      'MemoryConsolidationJobOutput(merges=$merges, supersedes=$supersedes)';
}
