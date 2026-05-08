import 'package:drift/drift.dart';

import 'memory_items.dart';

/// L2-normalized e5 embedding for a memory card.
class MemoryEmbeddings extends Table {
  /// Owning memory card.
  TextColumn get memoryId => text().references(MemoryItems, #id)();

  /// Embedding dimension. e5-small-v2 is 384 in production, but tests may use
  /// smaller vectors.
  IntColumn get dim => integer()();

  /// Raw Float32List bytes.
  BlobColumn get embedding => blob()();

  @override
  Set<Column<Object>> get primaryKey => {memoryId};
}
