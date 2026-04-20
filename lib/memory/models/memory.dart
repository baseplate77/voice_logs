import 'package:meta/meta.dart';

/// Strongly-typed memory id — distinct from `String` so callers can't
/// swap it for a chunk id or log id. Backed by a UUID/ULID produced at
/// extraction time.
extension type const MemoryId(String raw) {}

/// The four memory kinds a transcript can be distilled into.
///
/// Single polymorphic storage — see `memories` table — keyed on this
/// enum. The kind picks which optional columns (occurredAt, dueAt,
/// goalState) carry meaning.
enum MemoryKind {
  /// Stable proposition about the user ("I work at Acme").
  fact,

  /// Timestamped choice that can be superseded ("decided Postgres").
  decision,

  /// Narrative event tied to a recording ("tough 1:1 with P").
  episode,

  /// State-tracked goal ("ship v1 by June").
  goal,
}

/// Lifecycle of a memory row.
///
/// - [active]: current, feeds retrieval + profile.
/// - [superseded]: replaced by a newer memory; `supersededById` points
///   to the replacement.
/// - [resolved]: goal-only — the goal was achieved.
/// - [archived]: user or extractor rejected; kept as negative signal
///   for future extraction prompts but hidden from retrieval.
enum MemoryStatus { active, superseded, resolved, archived }

/// State of a [GoalMemory]. Irrelevant to other kinds.
enum GoalState { open, inProgress, done, abandoned }

/// A persisted memory record. Every concrete subclass carries the same
/// base metadata; kind-specific fields hang off the subclass.
///
/// `createdAt` / `updatedAt` / `confidence` / `status` are set by the
/// repository; [MemoryExtractor] produces [MemoryCandidate] instances
/// that the consolidator turns into [Memory]s on save.
@immutable
sealed class Memory {
  const Memory({
    required this.id,
    required this.kind,
    required this.title,
    required this.content,
    required this.status,
    required this.confidence,
    required this.createdAt,
    required this.updatedAt,
    required this.supersededById,
    required this.sourceChunkIds,
    required this.entityIds,
  })  : assert(confidence >= 0.0 && confidence <= 1.0),
        assert(title.length > 0, 'memory title must be non-empty'),
        assert(content.length > 0, 'memory content must be non-empty');

  final MemoryId id;
  final MemoryKind kind;

  /// Short retrieval-friendly handle, ~10 words. Indexed in FTS.
  final String title;

  /// Canonical 1–3 sentence phrasing. Also indexed in FTS.
  final String content;

  final MemoryStatus status;

  /// Extractor-assigned confidence in (0, 1]. Consolidator may bump
  /// this on merge.
  final double confidence;

  final DateTime createdAt;
  final DateTime updatedAt;

  /// When [status] == [MemoryStatus.superseded], points to the newer
  /// memory that replaced this one. Null otherwise.
  final MemoryId? supersededById;

  /// Chunk ids (from `transcript_chunks.id`) that the extractor tied to
  /// this memory. Stored via `memory_sources` join table.
  final List<int> sourceChunkIds;

  /// Entity ids (from `entities.id`) mentioned by this memory. Stored
  /// via `memory_entities` join table. Empty when the extractor found
  /// no matching canonical entity.
  final List<int> entityIds;

  @override
  String toString() => 'Memory(${id.raw} $kind "$title")';
}

/// A stable proposition about the user or their world.
final class FactMemory extends Memory {
  const FactMemory({
    required super.id,
    required super.title,
    required super.content,
    required super.status,
    required super.confidence,
    required super.createdAt,
    required super.updatedAt,
    super.supersededById,
    super.sourceChunkIds = const <int>[],
    super.entityIds = const <int>[],
  }) : super(kind: MemoryKind.fact);
}

/// A choice the user recorded. `occurredAt` is when the decision was
/// *made* — not when the recording happened (the extractor may resolve
/// a relative phrase like "yesterday" into a concrete date).
final class DecisionMemory extends Memory {
  const DecisionMemory({
    required super.id,
    required super.title,
    required super.content,
    required super.status,
    required super.confidence,
    required super.createdAt,
    required super.updatedAt,
    required this.occurredAt,
    super.supersededById,
    super.sourceChunkIds = const <int>[],
    super.entityIds = const <int>[],
  }) : super(kind: MemoryKind.decision);

  final DateTime occurredAt;
}

/// A narrative event. `occurredAt` is required; episodes without a
/// time point fold back into [FactMemory].
final class EpisodeMemory extends Memory {
  const EpisodeMemory({
    required super.id,
    required super.title,
    required super.content,
    required super.status,
    required super.confidence,
    required super.createdAt,
    required super.updatedAt,
    required this.occurredAt,
    super.supersededById,
    super.sourceChunkIds = const <int>[],
    super.entityIds = const <int>[],
  }) : super(kind: MemoryKind.episode);

  final DateTime occurredAt;
}

/// An ongoing objective. `state` tracks progress; `dueAt` is an
/// optional target date.
final class GoalMemory extends Memory {
  const GoalMemory({
    required super.id,
    required super.title,
    required super.content,
    required super.status,
    required super.confidence,
    required super.createdAt,
    required super.updatedAt,
    required this.state,
    this.dueAt,
    super.supersededById,
    super.sourceChunkIds = const <int>[],
    super.entityIds = const <int>[],
  }) : super(kind: MemoryKind.goal);

  final GoalState state;
  final DateTime? dueAt;
}
