import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'database.dart';
import 'repositories/entity_mention_repository.dart';
import 'repositories/voice_log_repository.dart';

/// The single live database instance. Disposed when the providers tear
/// down — during app shutdown or in tests.
final voxSynthDatabaseProvider = Provider<VoxSynthDatabase>((ref) {
  final db = VoxSynthDatabase(openVoxSynthDatabase());
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

/// Reverse-chronological stream of voice logs. Home screen subscribes to
/// this.
final voiceLogsStreamProvider = StreamProvider<List<VoiceLogView>>((ref) {
  final repo = ref.watch(voiceLogRepositoryProvider);
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
