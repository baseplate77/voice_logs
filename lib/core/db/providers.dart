import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'database.dart';
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

/// Reverse-chronological stream of voice logs. Home screen subscribes to
/// this.
final voiceLogsStreamProvider = StreamProvider<List<VoiceLogView>>((ref) {
  final repo = ref.watch(voiceLogRepositoryProvider);
  return repo.watchAll();
});
