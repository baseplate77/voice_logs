import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/actions/action_types.dart';
import '../../features/memory/memory_types.dart';
import 'database.dart';
import 'repositories/action_item_repository.dart';
import 'repositories/ask_chat_repository.dart';
import 'repositories/canonical_entity_repository.dart';
import 'repositories/entity_mention_repository.dart';
import 'repositories/entity_summary_repository.dart';
import 'repositories/log_summary_repository.dart';
import 'repositories/memory_repository.dart';
import 'repositories/prompt_suggestion_repository.dart';
import 'repositories/transcript_segment_repository.dart';
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

/// Repository for extracted local action items.
final actionItemRepositoryProvider = Provider<ActionItemRepository>((ref) {
  final db = ref.watch(voxSynthDatabaseProvider);
  return ActionItemRepository(db);
});

/// Repository for persisted Ask Journal threads and messages.
final askChatRepositoryProvider = Provider<AskChatRepository>((ref) {
  final db = ref.watch(voxSynthDatabaseProvider);
  return AskChatRepository(db);
});

/// Repository for per-log structured summaries (one-liner, bullets,
/// people/projects, decisions, follow-ups). Writes to the polymorphic
/// `summaries` table under `type = 'log'`.
final logSummaryRepositoryProvider = Provider<LogSummaryRepository>((ref) {
  final db = ref.watch(voxSynthDatabaseProvider);
  return LogSummaryRepository(db);
});

/// Live summary view for a single log. Detail screen subscribes; emits
/// `null` until the summarize job lands and then re-emits as the row
/// updates or is replaced.
final logSummaryForLogProvider = StreamProvider.family<LogSummaryView?, String>(
  (ref, logId) {
    final repo = ref.watch(logSummaryRepositoryProvider);
    return repo.watchByLogId(logId);
  },
);

/// Repository for tap-to-ask suggestion chips extracted per log.
final promptSuggestionRepositoryProvider = Provider<PromptSuggestionRepository>(
  (ref) {
    final db = ref.watch(voxSynthDatabaseProvider);
    return PromptSuggestionRepository(db);
  },
);

/// Live stream of every suggestion chip across all logs. The Ask screen
/// applies its selector over this snapshot so the chip row updates as new
/// refinements land.
final promptSuggestionsStreamProvider =
    StreamProvider<List<PromptSuggestionView>>((ref) {
      final repo = ref.watch(promptSuggestionRepositoryProvider);
      return repo.watchAll();
    });

/// Repository for Gemma-generated entity narrative summaries.
final entitySummaryRepositoryProvider = Provider<EntitySummaryRepository>((
  ref,
) {
  final db = ref.watch(voxSynthDatabaseProvider);
  return EntitySummaryRepository(db);
});

/// Reactive summary for a single canonical entity. Emits null when no row
/// has been generated yet so the entity page can show a skeleton.
final entitySummaryForEntityProvider =
    StreamProvider.family<EntitySummaryView?, String>((ref, entityId) {
      final repo = ref.watch(entitySummaryRepositoryProvider);
      return repo.watchForEntity(entityId);
    });

/// Voice logs that mention a given canonical entity, newest first.
/// Powers the "Conversations / Timeline" section of the entity page.
final voiceLogsForEntityProvider =
    StreamProvider.family<List<VoiceLogView>, String>((ref, entityId) async* {
      final mentions = ref.watch(entityMentionRepositoryProvider);
      final logs = ref.watch(voiceLogRepositoryProvider);
      await for (final logIds in mentions.watchLogIdsForEntity(entityId)) {
        final rows = <VoiceLogView>[];
        for (final id in logIds) {
          final view = await logs.find(id);
          if (view != null) rows.add(view);
        }
        yield rows;
      }
    });

/// Pending action items derived from logs that mention a given canonical
/// entity. Drives the "Open tasks" section. Decisions (type='decision')
/// are returned in the same stream — the UI splits them out as needed.
final actionItemsForEntityProvider =
    StreamProvider.family<List<VoiceActionItemView>, String>((
      ref,
      entityId,
    ) async* {
      final mentions = ref.watch(entityMentionRepositoryProvider);
      final actions = ref.watch(actionItemRepositoryProvider);
      await for (final logIds in mentions.watchLogIdsForEntity(entityId)) {
        final all = <VoiceActionItemView>[];
        for (final id in logIds) {
          all.addAll(await actions.forLog(id));
        }
        // Pending first, then by due date. Archived/done filtered out so
        // the entity page only surfaces actionable items.
        all.removeWhere((a) => a.status == VoiceActionStatus.archived);
        all.sort((a, b) {
          final byStatus = a.status.index.compareTo(b.status.index);
          if (byStatus != 0) return byStatus;
          final aDue = a.dueAt?.millisecondsSinceEpoch ?? 1 << 62;
          final bDue = b.dueAt?.millisecondsSinceEpoch ?? 1 << 62;
          return aDue.compareTo(bDue);
        });
        yield all;
      }
    });

/// Repository for STT segment timings (per-word scrub data).
final transcriptSegmentRepositoryProvider =
    Provider<TranscriptSegmentRepository>((ref) {
      final db = ref.watch(voxSynthDatabaseProvider);
      return TranscriptSegmentRepository(db);
    });

/// One-shot list of transcript segments for a log. Detail screen reads
/// this once per log open — segments don't change after insertion.
final transcriptSegmentsForLogProvider = FutureProvider.family
    .autoDispose<List<TranscriptSegmentView>, String>((ref, logId) {
      final repo = ref.watch(transcriptSegmentRepositoryProvider);
      return repo.findByLogId(logId);
    });

/// Reverse-chronological stream of voice logs. Home screen subscribes to
/// this.
final voiceLogsStreamProvider = StreamProvider<List<VoiceLogView>>((ref) {
  final repo = ref.watch(voiceLogRepositoryProvider);
  return repo.watchAll();
});

/// Bumped when a refine job lands so the home list rebinds even if the
/// drift watch notification is delayed across isolates.
final voiceLogListRevisionProvider = StateProvider<int>((ref) => 0);

/// Stream of local memory cards for the Memory screen.
final memoryItemsStreamProvider = StreamProvider<List<MemoryItemView>>((ref) {
  final repo = ref.watch(memoryRepositoryProvider);
  return repo.watchAll();
});

/// Stream of extracted actions for the Action Inbox.
final actionItemsStreamProvider = StreamProvider<List<VoiceActionItemView>>((
  ref,
) {
  final repo = ref.watch(actionItemRepositoryProvider);
  return repo.watchInbox();
});

/// Per-log count of *pending* action items, derived from
/// [actionItemsStreamProvider]. Used by the home list to badge cards whose
/// extracted tasks still need attention; once everything is done or
/// archived for a log the entry disappears so the row de-clutters itself.
final pendingActionCountsByLogProvider = Provider<Map<String, int>>((ref) {
  final actionsAsync = ref.watch(actionItemsStreamProvider);
  final actions = actionsAsync.valueOrNull;
  if (actions == null || actions.isEmpty) return const {};
  final counts = <String, int>{};
  for (final action in actions) {
    if (action.status != VoiceActionStatus.pending) continue;
    counts.update(
      action.voiceLogId,
      (current) => current + 1,
      ifAbsent: () => 1,
    );
  }
  return counts;
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
