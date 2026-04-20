import 'package:objectbox/objectbox.dart';

/// A 384-dimensional, L2-normalised embedding for one [TranscriptChunks]
/// row.
///
/// Kept deliberately minimal — ObjectBox is our HNSW index and nothing
/// else; metadata lives in Drift. The [id] matches `chunks.objectbox_id`
/// so a single lookup by int bridges the two stores.
///
/// IMPLEMENTATION_PLAN §5 "Gotchas" flags that ObjectBox stores vectors
/// as `List<double>`, not `Float32List`. The repository layer converts
/// at the API boundary so callers stay on Float32List everywhere else.
@Entity()
class ChunkVector {
  ChunkVector({this.id = 0, required this.embedding, required this.logId});

  /// ObjectBox-assigned id when 0 → auto-assign on put. The returned
  /// id is what we store into `chunks.objectbox_id`.
  @Id()
  int id;

  /// The Drift `voice_logs.id` this vector's chunk belongs to.
  /// Denormalised here so a single-store delete by log id is possible
  /// even if the Drift row has already been wiped.
  @Index()
  String logId;

  /// 384-dim vector from multilingual-e5-small (Phase 4a). Stored as
  /// `List<double>` per ObjectBox's HNSW contract; the repo wraps it
  /// in Float32List on the way out. `@Property(type:
  /// PropertyType.floatVector)` is required — ObjectBox won't attach
  /// @HnswIndex to a double-typed list otherwise.
  @Property(type: PropertyType.floatVector)
  @HnswIndex(dimensions: 384, distanceType: VectorDistanceType.cosine)
  List<double> embedding;
}

/// A 384-dimensional, L2-normalised embedding for one memory record
/// (Phase 8).
///
/// Sibling of [ChunkVector] — separate box so memory retrieval doesn't
/// need to filter chunk vectors out on every query, and so supersedence
/// / archive states can be reflected by presence/absence rather than a
/// SQL join. The [memoryId] is the `memories.id` TEXT primary key; kept
/// denormalised here so `removeByMemoryId` is a single-store operation.
@Entity()
class MemoryVector {
  MemoryVector({
    this.id = 0,
    required this.memoryId,
    required this.embedding,
  });

  /// ObjectBox-assigned id when 0 → auto-assign on put. Stored back
  /// into `memories.objectbox_id`.
  @Id()
  int id;

  /// `memories.id` (UUID/ULID string). Indexed so delete-by-id is
  /// cheap.
  @Index()
  String memoryId;

  /// 384-dim vector from multilingual-e5-small.
  @Property(type: PropertyType.floatVector)
  @HnswIndex(dimensions: 384, distanceType: VectorDistanceType.cosine)
  List<double> embedding;
}
