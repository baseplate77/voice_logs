import 'package:drift/drift.dart';

import 'canonical_entities.dart';
import 'memory_items.dart';

/// Join table linking memory cards to canonical entities.
class MemoryEntityLinks extends Table {
  /// Owning memory card.
  TextColumn get memoryId => text().references(MemoryItems, #id)();

  /// Linked canonical entity.
  TextColumn get canonicalEntityId =>
      text().references(CanonicalEntities, #id)();

  @override
  Set<Column<Object>> get primaryKey => {memoryId, canonicalEntityId};
}
