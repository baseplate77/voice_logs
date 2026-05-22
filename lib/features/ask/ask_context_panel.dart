import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../core/db/providers.dart';
import '../../core/db/repositories/entity_mention_repository.dart';
import '../entity/entity_detail_screen.dart';
import '../memory/memory_types.dart';
import '../search/hybrid_retriever.dart';
import 'ask_chat_message.dart';
import 'ask_prompt_templates.dart';

/// Callback invoked when the user opens a voice-log source. The caller is
/// responsible for resolving the snippet to an audio offset and pushing
/// LogDetailScreen with the right deep-link params.
typedef OpenLogCallback = void Function(SearchHit hit);

/// Expanded source list for an Ask answer. Tiles are numbered to match
/// the inline `[L#]` / `[M#]` citation chips in [AskAnswerView] so users
/// can map a footnote to its source without guessing.
class AskContextPanel extends StatelessWidget {
  const AskContextPanel({
    super.key,
    required this.message,
    required this.onOpenLog,
  });

  /// Assistant message containing retrieval context.
  final AskChatMessage message;

  /// Called when the user taps a retrieved voice-log source.
  final OpenLogCallback onOpenLog;

  @override
  Widget build(BuildContext context) {
    final memoryTiles = [
      for (var i = 0; i < message.memoryHits.length; i++)
        _MemoryTile(index: i + 1, hit: message.memoryHits[i]),
    ];
    final logTiles = [
      for (var i = 0; i < message.logHits.length; i++)
        _LogTile(
          index: i + 1,
          hit: message.logHits[i],
          onTap: () => onOpenLog(message.logHits[i]),
        ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.symmetric(vertical: 4.h),
          child: Text(
            'Sources',
            style: Theme.of(context).textTheme.labelMedium,
          ),
        ),
        ...memoryTiles,
        ...logTiles,
      ],
    );
  }
}

class _IndexBadge extends StatelessWidget {
  const _IndexBadge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 6.w, vertical: 2.h),
      decoration: BoxDecoration(
        color: scheme.primary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8.r),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12.sp,
          fontWeight: FontWeight.w700,
          color: scheme.primary,
        ),
      ),
    );
  }
}

class _MemoryTile extends StatelessWidget {
  const _MemoryTile({required this.index, required this.hit});

  final int index;
  final MemoryHit hit;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      leading: _IndexBadge(label: '[M$index]'),
      title: Text(hit.memory.text),
      subtitle: Text(
        'memory • ${hit.memory.type.wire} • ${_memorySources(hit.matchedVia)}',
      ),
    );
  }
}

class _LogTile extends ConsumerWidget {
  const _LogTile({required this.index, required this.hit, required this.onTap});

  final int index;
  final SearchHit hit;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final mentionsAsync = ref.watch(voiceLogMentionsProvider(hit.logId));
    // Only show entity chips for mentions that have been canonicalized.
    // Mentions whose canonicalization hasn't run yet are useless for
    // navigation — there's no entity page to open.
    final entityMentions = mentionsAsync.maybeWhen(
      data: (m) =>
          m.where((e) => e.canonicalEntityId != null).toList(growable: false),
      orElse: () => <EntityMentionView>[],
    );
    final seenIds = <String>{};
    final uniqueEntities = <EntityMentionView>[];
    for (final m in entityMentions) {
      final id = m.canonicalEntityId!;
      if (seenIds.add(id)) uniqueEntities.add(m);
    }

    return Padding(
      padding: EdgeInsets.only(bottom: 4.h),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListTile(
            dense: true,
            leading: _IndexBadge(label: '[L$index]'),
            title: Text(formatLogSourceLabel(hit)),
            subtitle: Text(
              '${hit.snippet}\nvoice log • ${_logSources(hit.matchedVia)} • tap to listen',
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
            ),
            onTap: onTap,
          ),
          if (uniqueEntities.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
              child: Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  for (final m in uniqueEntities.take(6))
                    InputChip(
                      label: Text(m.text),
                      avatar: Icon(
                        _entityIcon(m.type),
                        size: 14.r,
                        color: theme.colorScheme.primary,
                      ),
                      visualDensity: VisualDensity.compact,
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => EntityDetailScreen(
                            entityId: m.canonicalEntityId!,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

IconData _entityIcon(String type) {
  switch (type.toUpperCase()) {
    case 'PERSON':
      return Icons.person_outline;
    case 'PLACE':
      return Icons.place_outlined;
    case 'PROJECT':
      return Icons.work_outline;
    case 'TIME':
      return Icons.schedule_outlined;
    default:
      return Icons.label_outline;
  }
}

String _memorySources(Set<MemoryMatchSource> sources) {
  if (sources.isEmpty) return 'retrieved';
  return sources
      .map((source) {
        return switch (source) {
          MemoryMatchSource.fts => 'keyword',
          MemoryMatchSource.vector => 'semantic',
          MemoryMatchSource.entity => 'entity',
        };
      })
      .join(' + ');
}

String _logSources(Set<MatchSource> sources) {
  if (sources.isEmpty) return 'retrieved';
  return sources
      .map((source) {
        return switch (source) {
          MatchSource.fts => 'keyword',
          MatchSource.vector => 'semantic',
          MatchSource.entity => 'entity',
        };
      })
      .join(' + ');
}
