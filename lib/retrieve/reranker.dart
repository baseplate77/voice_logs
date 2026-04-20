import 'dart:convert';

import '../core/logger.dart';
import '../llm/llm_runner.dart';
import '../llm/prompt_templates.dart';
import '../store/models/voice_log_record.dart';

/// Candidate chunk presented to the reranker. We keep the repo's
/// [ChunkRecord] opaque so the prompt can display whatever text is
/// useful; callers pair results by `id`.
final class RerankCandidate {
  const RerankCandidate({required this.chunk});
  final ChunkRecord chunk;
}

/// Per-candidate LLM relevance score in [0, 1]. NaN when the LLM
/// didn't score that candidate (malformed output, missing index).
final class RerankScore {
  const RerankScore({required this.chunkId, required this.score});
  final int chunkId;
  final double score;
}

/// Truncate chunk text shown in the rerank prompt. Past ~200 words
/// per candidate the 20-chunk fit-in-context budget explodes —
/// IMPLEMENTATION_PLAN §6 calls for a summary in that case; we settle
/// for a crude truncation with an ellipsis because a summary pass
/// would be another LLM call per chunk.
const int kRerankMaxCharsPerChunk = 1200;

/// Total cap on candidates we'll ask the LLM to rerank. Anything past
/// 20 is too much context for Gemma 3 1B's 8k window with the
/// instruction prompt + JSON reply space.
const int kRerankMaxCandidates = 20;

const PromptTemplate _rerankTemplate = PromptTemplate(
  name: 'reranker',
  body: '''
You are VoxSynth's retrieval reranker. Given a user query and a
numbered list of candidate transcript chunks, score each one from 0
(irrelevant) to 10 (directly answers the query).

Be strict: 10 means the chunk contains the answer verbatim or near
it; 7 means it's highly related; 3 means the topic overlaps but
nothing useful; 0 means noise.

Output ONLY a JSON object keyed by candidate tag:
  {"C1": 9, "C2": 2, "C3": 7, ...}

Do not include any prose, markdown, or candidates you couldn't score.

Query:
{{query}}

Candidates:
{{candidates}}
''',
  requiredVariables: <String>['query', 'candidates'],
);

const PromptTemplate _rerankRetryTemplate = PromptTemplate(
  name: 'reranker_retry',
  body: '''
Your previous response was not valid JSON. Respond with ONLY a JSON
object mapping candidate tag (e.g. "C1") to integer score 0-10.

Query:
{{query}}

Candidates:
{{candidates}}
''',
  requiredVariables: <String>['query', 'candidates'],
);

/// LLM-based reranker. Scores candidates once, retries once with a
/// stricter prompt on malformed JSON, then falls back to
/// `RerankScore.nan` for every candidate so the caller keeps the
/// input order.
class Reranker {
  Reranker({required this.runner, AppLogger? logger})
      : _logger = logger ?? AppLogger();

  final LlmRunner runner;
  final AppLogger _logger;

  /// Score [candidates] for [query]. Output length matches input.
  /// Missing scores arrive as `double.nan`.
  Future<List<RerankScore>> rerank({
    required String query,
    required List<RerankCandidate> candidates,
  }) async {
    if (candidates.isEmpty) return const <RerankScore>[];
    final capped = candidates.length > kRerankMaxCandidates
        ? candidates.sublist(0, kRerankMaxCandidates)
        : candidates;

    final promptCandidates = _formatCandidates(capped);
    final first = await runner.generateSync(
      _rerankTemplate.render(<String, String>{
        'query': query,
        'candidates': promptCandidates,
      }),
    );
    Map<String, double>? parsed;
    if (first.isOk) {
      parsed = _parse(first.okOrNull!);
      if (parsed == null) {
        _logger.warn('Rerank JSON parse failed; retrying');
      }
    } else {
      _logger.warn(
        'Rerank call failed; retrying',
        error: first.errOrNull,
      );
    }

    if (parsed == null) {
      final retry = await runner.generateSync(
        _rerankRetryTemplate.render(<String, String>{
          'query': query,
          'candidates': promptCandidates,
        }),
      );
      if (retry.isOk) {
        parsed = _parse(retry.okOrNull!);
      }
    }

    return _materialise(capped, parsed);
  }

  static String _formatCandidates(List<RerankCandidate> candidates) {
    final buf = StringBuffer();
    for (var i = 0; i < candidates.length; i++) {
      final tag = 'C${i + 1}';
      final text = candidates[i].chunk.text;
      final snippet = text.length > kRerankMaxCharsPerChunk
          ? '${text.substring(0, kRerankMaxCharsPerChunk)}…'
          : text;
      buf
        ..write('[')
        ..write(tag)
        ..write('] ')
        ..write(snippet)
        ..writeln();
    }
    return buf.toString();
  }

  /// Parse the JSON; normalise each score into [0, 1] so fused score
  /// math doesn't have to know about the 0-10 scale.
  static Map<String, double>? _parse(String raw) {
    final cleaned = _stripCodeFences(raw);
    final Object? decoded;
    try {
      decoded = jsonDecode(cleaned);
    } on FormatException {
      return null;
    }
    if (decoded is! Map) return null;
    final out = <String, double>{};
    decoded.forEach((k, v) {
      if (k is! String) return;
      if (!_tagPattern.hasMatch(k)) return;
      if (v is num) {
        final clamped = v.toDouble().clamp(0.0, 10.0).toDouble();
        out[k] = clamped / 10.0;
      }
    });
    return out;
  }

  static List<RerankScore> _materialise(
    List<RerankCandidate> candidates,
    Map<String, double>? parsed,
  ) {
    final out = <RerankScore>[];
    for (var i = 0; i < candidates.length; i++) {
      final tag = 'C${i + 1}';
      final score = parsed?[tag];
      out.add(
        RerankScore(
          chunkId: candidates[i].chunk.id,
          score: score ?? double.nan,
        ),
      );
    }
    return out;
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

  static final RegExp _tagPattern = RegExp(r'^C\d+$');
}
