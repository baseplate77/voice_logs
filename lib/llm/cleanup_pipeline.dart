import 'dart:convert';

import '../asr/models/transcript.dart';
import '../core/errors.dart';
import '../core/logger.dart';
import '../core/result.dart';
import 'llm_runner.dart';
import 'models/cleaned_transcript.dart';
import 'prompt_templates.dart';
import 'topic_chunker.dart';

/// Transforms a raw [Transcript] (from Phase 2 ASR) into a cleaned,
/// chunked, entity-tagged [CleanedTranscript] via four calls to an
/// [LlmRunner]: cleanup → boundaries → entities (with one retry on bad
/// JSON) → tags.
///
/// All four calls run strictly sequentially. An earlier version fired
/// cleanup/entities/tags concurrently, but holding three live Gemma
/// sessions at once blew through mobile-device memory and crashed the
/// app — flutter_gemma's KV cache is per-session on GPU. Stay serial.
///
/// The pipeline is deliberately LLM-backend-agnostic — swap in any
/// [LlmRunner] (Gemma, llama.cpp, a fake) without touching this class.
///
/// Every step degrades gracefully:
///   - cleanup failure → bail with an [AppError] (required step)
///   - boundaries failure → fall back to fixed-width chunks
///   - entity extraction JSON parse failure → retry once with a
///     stricter prompt, then fall back to []
///   - tags JSON parse failure → fall back to []
class CleanupPipeline {
  CleanupPipeline({required this.runner, AppLogger? logger})
      : _logger = logger ?? AppLogger(),
        _chunker = const TopicChunker();

  final LlmRunner runner;
  final AppLogger _logger;
  final TopicChunker _chunker;

  /// Clean [raw] and return a structured view. Runs the four LLM calls
  /// one after the other on the cleaned text — see the class-level doc
  /// for why concurrency is off the table.
  Future<Result<CleanedTranscript, AppError>> clean(Transcript raw) async {
    if (raw.text.isEmpty) {
      return const Ok<CleanedTranscript, AppError>(CleanedTranscript.empty);
    }

    // Step 1: cleanup.
    final cleanupPrompt = cleanupTemplate.render(<String, String>{
      'transcript': raw.text,
    });
    final cleanupResult = await runner.generateSync(cleanupPrompt);
    if (cleanupResult.isErr) {
      _logger.error(
        'Cleanup failed',
        error: cleanupResult.errOrNull,
      );
      return Err<CleanedTranscript, AppError>(cleanupResult.errOrNull!);
    }
    final cleanedText = cleanupResult.okOrNull!.trim();
    if (cleanedText.isEmpty) {
      return const Ok<CleanedTranscript, AppError>(CleanedTranscript.empty);
    }

    // Step 2: boundaries (→ chunks, with fixed-width fallback).
    final chunks = await _chunkWithFallback(cleanedText);

    // Step 3: entities (with one retry on bad JSON).
    final entities = await _extractEntitiesWithRetry(cleanedText);

    // Step 4: tags.
    final tags = await _extractTags(cleanedText);

    return Ok<CleanedTranscript, AppError>(
      CleanedTranscript(
        text: cleanedText,
        chunks: chunks,
        entities: entities,
        tags: tags,
      ),
    );
  }

  Future<List<TopicChunk>> _chunkWithFallback(String text) async {
    final annotated = _annotateOffsets(text);
    final prompt = chunkBoundariesTemplate.render(<String, String>{
      'annotated_transcript': annotated,
    });
    final result = await runner.generateSync(prompt);
    if (result.isErr) {
      _logger.warn(
        'Boundary LLM call failed; using fixed-width fallback',
        error: result.errOrNull,
      );
      return _chunker.chunk(text, null).chunks;
    }
    final boundaries = _parseBoundaries(result.okOrNull!);
    final chunkResult = _chunker.chunk(text, boundaries);
    if (chunkResult.isFallback) {
      _logger.warn(
        'Chunker fell back to fixed-width: ${chunkResult.fallbackReason.name}',
      );
    }
    return chunkResult.chunks;
  }

  Future<List<Entity>> _extractEntitiesWithRetry(String text) async {
    final firstPrompt = entityExtractionTemplate.render(<String, String>{
      'transcript': text,
    });
    final firstResult = await runner.generateSync(firstPrompt);
    if (firstResult.isOk) {
      final parsed = _parseEntities(firstResult.okOrNull!);
      if (parsed != null) return parsed;
      _logger.warn('Entity JSON parse failed; retrying with stricter prompt');
    } else {
      _logger.warn(
        'Entity call failed; retrying with stricter prompt',
        error: firstResult.errOrNull,
      );
    }

    final retryPrompt = entityExtractionRetryTemplate.render(<String, String>{
      'transcript': text,
    });
    final retryResult = await runner.generateSync(retryPrompt);
    if (retryResult.isOk) {
      final parsed = _parseEntities(retryResult.okOrNull!);
      if (parsed != null) return parsed;
    }
    _logger.warn('Entity extraction failed after retry; returning empty list');
    return const <Entity>[];
  }

  Future<List<String>> _extractTags(String text) async {
    final prompt = tagsTemplate.render(<String, String>{'transcript': text});
    final result = await runner.generateSync(prompt);
    if (result.isErr) return const <String>[];
    final parsed = _parseTags(result.okOrNull!);
    return parsed ?? const <String>[];
  }

  /// Annotate the cleaned transcript with `⟨N⟩` markers every 200
  /// characters. Lets the LLM cite char offsets directly in its JSON
  /// output instead of having to count.
  static String _annotateOffsets(String text) {
    const step = 200;
    final buf = StringBuffer();
    for (var i = 0; i < text.length; i += step) {
      buf.write('⟨$i⟩ ');
      final end = (i + step).clamp(0, text.length);
      buf.write(text.substring(i, end));
    }
    return buf.toString();
  }

  /// Parse the chunk-boundaries JSON. `null` means malformed —
  /// [_chunkWithFallback] routes that through [TopicChunker]'s
  /// fixed-width fallback path.
  static List<ProposedBoundary>? _parseBoundaries(String raw) {
    final cleaned = _stripCodeFences(raw);
    final parsed = _decodeJson(cleaned);
    if (parsed is! List) return null;
    final out = <ProposedBoundary>[];
    for (final e in parsed) {
      if (e is! Map) return null;
      final start = e['start'];
      final end = e['end'];
      final topic = e['topic'];
      if (start is! int || end is! int || topic is! String) return null;
      out.add(ProposedBoundary(start: start, end: end, topic: topic));
    }
    return out;
  }

  /// Parse entity-extraction JSON. Same `null = malformed` contract.
  static List<Entity>? _parseEntities(String raw) {
    final cleaned = _stripCodeFences(raw);
    final parsed = _decodeJson(cleaned);
    if (parsed is! List) return null;
    final out = <Entity>[];
    for (final e in parsed) {
      if (e is! Map) return null;
      final name = e['name'];
      final kind = e['kind'];
      if (name is! String || name.isEmpty) return null;
      if (kind is! String) return null;
      final aliases = <String>[];
      final rawAliases = e['aliases'];
      if (rawAliases is List) {
        for (final a in rawAliases) {
          if (a is String) aliases.add(a);
        }
      }
      var salience = 0.5;
      final rawSalience = e['salience'];
      if (rawSalience is num) {
        salience = rawSalience.toDouble().clamp(0.0, 1.0).toDouble();
      }
      out.add(
        Entity(
          name: name,
          kind: kind,
          aliases: aliases,
          salience: salience,
        ),
      );
    }
    return out;
  }

  /// Parse a `["tag1","tag2"]` JSON array. `null` on failure.
  static List<String>? _parseTags(String raw) {
    final cleaned = _stripCodeFences(raw);
    final parsed = _decodeJson(cleaned);
    if (parsed is! List) return null;
    final out = <String>[];
    for (final e in parsed) {
      if (e is! String) return null;
      out.add(e);
    }
    return out;
  }

  /// LLMs frequently wrap JSON in ```json ... ``` despite being told not
  /// to. Strip markdown code fences before decoding.
  static String _stripCodeFences(String raw) {
    var s = raw.trim();
    if (s.startsWith('```')) {
      final firstNl = s.indexOf('\n');
      if (firstNl >= 0) s = s.substring(firstNl + 1);
      if (s.endsWith('```')) s = s.substring(0, s.length - 3);
    }
    return s.trim();
  }

  static Object? _decodeJson(String s) {
    try {
      return jsonDecode(s);
    } on FormatException {
      return null;
    }
  }
}
