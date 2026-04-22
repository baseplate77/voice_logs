import 'package:drift/drift.dart';

/// One row per canonical entity in the user's personal graph. Mentions are
/// linked to these via `entity_mentions.canonical_entity_id`.
class CanonicalEntities extends Table {
  /// UUID v4.
  TextColumn get id => text()();

  /// User-editable display name. Defaults to the first mention's surface
  /// text at creation time.
  TextColumn get displayName => text()();

  /// One of: `PERSON` | `PLACE` | `PROJECT` | `DURATION` | `TIME` | `NUMBER`
  /// | `OTHER`.
  TextColumn get type => text()();

  /// Denormalized count of mentions pointing at this entity, maintained by
  /// the canonicalization pipeline.
  IntColumn get mentionCount => integer().withDefault(const Constant(0))();

  /// Unix milliseconds when the canonical entity was first created.
  IntColumn get createdAt => integer()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}
