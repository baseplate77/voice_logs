import 'package:drift/drift.dart';

import 'canonical_entities.dart';

/// Per-canonical-entity narrative summary surfaced on the entity detail
/// page ("People / Project pages" feature).
///
/// One row per canonical entity. Background job [JobType.entitySummary]
/// regenerates the summary when [mentionCountAtGeneration] drifts behind
/// the entity's current mention count. The repository is the single point
/// of truth for that staleness check so callers don't recompute it.
class EntitySummaries extends Table {
  /// Canonical entity this summary belongs to. Drives the primary key —
  /// each entity has at most one summary row.
  TextColumn get entityId => text().references(CanonicalEntities, #id)();

  /// 2-3 sentence Gemma-generated relationship / context summary. Falls
  /// back to a deterministic blurb when generation fails so the UI never
  /// renders an empty Context section.
  TextColumn get summaryText => text()();

  /// JSON-encoded `EntityStructuredFacts` — durable per-entity background
  /// (what they are, key facts, recent themes, last-merged log id, last
  /// full-rebuild bookkeeping). Nullable so legacy rows / fallback writes
  /// stay valid; the job rebuilds this incrementally as new mentions land.
  TextColumn get structuredFacts => text().nullable()();

  /// Mention count snapshot at the moment this summary was generated.
  /// Compared against [CanonicalEntities.mentionCount] to decide whether
  /// the summary is stale enough to warrant a fresh Gemma call.
  IntColumn get mentionCountAtGeneration => integer()();

  /// Tag of the model that produced this summary (e.g. `gemma-3-1b-it`).
  /// Lets us invalidate summaries en masse when we swap models.
  TextColumn get modelVersion => text()();

  /// Unix milliseconds when this row was written.
  IntColumn get generatedAt => integer()();

  @override
  Set<Column<Object>> get primaryKey => {entityId};
}
