import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/memory/memory_types.dart';
import 'database.dart';
import 'repositories/canonical_entity_repository.dart';
import 'repositories/entity_mention_repository.dart';
import 'repositories/memory_repository.dart';
import 'repositories/voice_log_repository.dart';

/// Absolute path to the app's documents directory. Resolved once in
/// `main()` via `path_provider` and injected as a ProviderScope override
/// so no code reads the plugin channel inside the first-frame build.
final appDocumentsPathProvider = Provider<String>((ref) {
  throw StateError(
    'appDocumentsPathProvider must be overridden in main() before runApp',
  );
});

/// The single live database instance. Disposed when the providers tear
/// down — during app shutdown or in tests.
final voxSynthDatabaseProvider = Provider<VoxSynthDatabase>((ref) {
  final docsPath = ref.watch(appDocumentsPathProvider);
  final db = VoxSynthDatabase(openVoxSynthDatabase(docsPath));
  ref.onDispose(db.close);
  return db;
});

/// Repository for the voice-log write/read path.
final voiceLogRepositoryProvider = Provider<VoiceLogRepository>((ref) {
  final db = ref.watch(voxSynthDatabaseProvider);
  return VoiceLogRepository(db);
});

/// Repository for entity mentions produced by the refine pipeline.
final entityMentionRepositoryProvider = Provider<EntityMentionRepository>((
  ref,
) {
  final db = ref.watch(voxSynthDatabaseProvider);
  return EntityMentionRepository(db);
});

/// Repository for canonical entities produced by the canonicalize job.
final canonicalEntityRepositoryProvider = Provider<CanonicalEntityRepository>((
  ref,
) {
  final db = ref.watch(voxSynthDatabaseProvider);
  return CanonicalEntityRepository(db);
});

/// Repository for local-only durable memories.
final memoryRepositoryProvider = Provider<MemoryRepository>((ref) {
  final db = ref.watch(voxSynthDatabaseProvider);
  return MemoryRepository(db);
});

/// Reverse-chronological stream of voice logs. Home screen subscribes to
/// this.
final voiceLogsStreamProvider = StreamProvider<List<VoiceLogView>>((ref) {
  final repo = ref.watch(voiceLogRepositoryProvider);
  return repo.watchAll();
});

/// Stream of local memory cards for the Memory screen.
final memoryItemsStreamProvider = StreamProvider<List<MemoryItemView>>((ref) {
  final repo = ref.watch(memoryRepositoryProvider);
  return repo.watchAll();
});

/// Stream of entity mentions for a specific log. Detail screen binds to
/// a family provider over the log id.
final voiceLogMentionsProvider =
    StreamProvider.family<List<EntityMentionView>, String>((ref, logId) {
      final repo = ref.watch(entityMentionRepositoryProvider);
      return repo.watchForLog(logId);
    });

/// Stream of a single voice log row for the detail screen.
final voiceLogByIdProvider = StreamProvider.family<VoiceLogView?, String>((
  ref,
  logId,
) async* {
  final repo = ref.watch(voiceLogRepositoryProvider);
  // Emit initial value then track changes through watchAll.
  yield await repo.find(logId);
  await for (final _ in repo.watchAll()) {
    yield await repo.find(logId);
  }
});
