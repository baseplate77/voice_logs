/// A single named entity extracted from a transcript.
///
/// Canonical form (`name`) is what downstream layers (Phase 4 `entities`
/// table, Phase 5 query expansion) should match against. `aliases` collect
/// alternative surface forms seen in this transcript so merging across
/// recordings is cheaper.
final class Entity {
  const Entity({
    required this.name,
    required this.kind,
    this.aliases = const <String>[],
    this.salience = 0.5,
  }) : assert(salience >= 0.0 && salience <= 1.0);

  /// Canonical name — lowercased for People/Projects, Title-Case for
  /// Organizations is fine. The cleanup prompt picks one canonical form.
  final String name;

  /// Rough category. The prompt uses an open enum; canonical values:
  /// `person`, `organization`, `project`, `product`, `decision`,
  /// `concept`. Unrecognised kinds are preserved verbatim so we can
  /// widen the enum later without dropping data.
  final String kind;

  /// Other spellings of the same entity seen in this transcript.
  final List<String> aliases;

  /// How central the entity is to this transcript, in [0, 1]. Used in
  /// Phase 5 reranking. Defaults to 0.5 when the LLM omits it.
  final double salience;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! Entity) return false;
    if (other.name != name) return false;
    if (other.kind != kind) return false;
    if (other.salience != salience) return false;
    if (other.aliases.length != aliases.length) return false;
    for (var i = 0; i < aliases.length; i++) {
      if (other.aliases[i] != aliases[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode =>
      Object.hash(name, kind, salience, Object.hashAll(aliases));

  @override
  String toString() => 'Entity($kind: $name)';
}

/// A coherent span of cleaned transcript text, typically 50-500 words.
///
/// Chunks are produced by [TopicChunker]. Offsets are Dart-string offsets
/// into `CleanedTranscript.text` — not word indices — so downstream
/// highlighting and citation code can slice without re-tokenising.
final class TopicChunk {
  const TopicChunk({
    required this.text,
    required this.startChar,
    required this.endChar,
    required this.topicHint,
    this.entityRefs = const <String>[],
  })  : assert(endChar > startChar),
        assert(startChar >= 0);

  final String text;
  final int startChar;
  final int endChar;

  /// Short human-readable label the LLM gave this chunk ("pricing
  /// discussion", "action items"). Not shown to users verbatim — used as
  /// a retrieval hint in Phase 5.
  final String topicHint;

  /// Canonical entity names mentioned in this chunk. Same strings as
  /// [Entity.name] values from the enclosing transcript.
  final List<String> entityRefs;

  /// Rough word count — used by [TopicChunker] validation and Phase 4
  /// embedding batching.
  int get wordCount => _tokenize(text).length;

  static List<String> _tokenize(String s) =>
      s.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! TopicChunk) return false;
    if (other.text != text) return false;
    if (other.startChar != startChar) return false;
    if (other.endChar != endChar) return false;
    if (other.topicHint != topicHint) return false;
    if (other.entityRefs.length != entityRefs.length) return false;
    for (var i = 0; i < entityRefs.length; i++) {
      if (other.entityRefs[i] != entityRefs[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
        text,
        startChar,
        endChar,
        topicHint,
        Object.hashAll(entityRefs),
      );

  @override
  String toString() =>
      'TopicChunk($startChar..$endChar, $wordCount words, "$topicHint")';
}

/// Post-cleanup view of a raw transcript.
///
/// Produced by [CleanupPipeline.clean]. Downstream consumers:
///   - Phase 4 ingest: one `voice_logs` row + one `chunks` row per
///     [TopicChunk] + one `entities` row per unique [Entity].
///   - Phase 5 retrieval: [chunks] are the retrieval unit; [entities]
///     seed query expansion.
final class CleanedTranscript {
  const CleanedTranscript({
    required this.text,
    required this.chunks,
    required this.entities,
    required this.tags,
  });

  /// Cleaned text: fillers removed, punctuation inserted, no fabricated
  /// content. 1:1 with the input transcript minus those edits.
  final String text;

  /// Semantic chunks spanning [text]. When [TopicChunker] falls back to
  /// fixed-width chunking, `topicHint` is the literal string
  /// `"(fixed-width fallback)"`.
  final List<TopicChunk> chunks;

  /// Unique entities across the whole transcript. Deduplicated by
  /// canonical [Entity.name] (case-insensitive).
  final List<Entity> entities;

  /// Free-form tags chosen by the LLM — topics at the document level
  /// rather than chunk level. Typically 1-4 per transcript.
  final List<String> tags;

  static const CleanedTranscript empty = CleanedTranscript(
    text: '',
    chunks: <TopicChunk>[],
    entities: <Entity>[],
    tags: <String>[],
  );

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! CleanedTranscript) return false;
    if (other.text != text) return false;
    if (!_listEq(other.chunks, chunks)) return false;
    if (!_listEq(other.entities, entities)) return false;
    if (!_listEq(other.tags, tags)) return false;
    return true;
  }

  @override
  int get hashCode => Object.hash(
        text,
        Object.hashAll(chunks),
        Object.hashAll(entities),
        Object.hashAll(tags),
      );

  @override
  String toString() =>
      'CleanedTranscript(${chunks.length} chunks, ${entities.length} entities, '
      '${tags.length} tags, ${text.length} chars)';

  static bool _listEq<T>(List<T> a, List<T> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
