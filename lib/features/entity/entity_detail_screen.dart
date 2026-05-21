import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../core/db/providers.dart';
import '../../core/db/repositories/canonical_entity_repository.dart';
import '../../core/db/repositories/entity_summary_repository.dart';
import '../../core/db/repositories/voice_log_repository.dart';
import '../actions/action_types.dart';
import '../detail/log_detail_screen.dart';

/// Detail page for a canonical entity — the "People / Project pages"
/// surface. Sections are unified across entity types; only the section
/// labels switch based on whether the entity is a PERSON, PROJECT, etc.
///
/// Sections:
///   * Header — display name, type chip, mention count.
///   * Conversations / Timeline — voice logs that mention this entity,
///     newest first. Tap opens the log detail screen.
///   * Decisions (PROJECT entities only) — action_items of type=decision
///     derived from logs that mention the entity.
///   * Open tasks — pending/done action_items from related logs.
///   * Context — Gemma-generated narrative blurb (from entity_summaries).
class EntityDetailScreen extends ConsumerWidget {
  const EntityDetailScreen({super.key, required this.entityId});

  /// Canonical entity id this page is rendering.
  final String entityId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entityAsync = ref.watch(_entityByIdProvider(entityId));
    return entityAsync.when(
      data: (entity) {
        if (entity == null) {
          return Scaffold(
            appBar: AppBar(title: const Text('Entity')),
            body: const Center(child: Text('Entity not found.')),
          );
        }
        return _EntityDetailContent(entity: entity);
      },
      loading: () => const Scaffold(
        body: Center(child: CircularProgressIndicator.adaptive()),
      ),
      error: (e, _) => Scaffold(
        appBar: AppBar(title: const Text('Entity')),
        body: Center(child: Text('Error: $e')),
      ),
    );
  }
}

class _EntityDetailContent extends ConsumerWidget {
  const _EntityDetailContent({required this.entity});

  final CanonicalEntityView entity;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final labels = _SectionLabels.forType(entity.type);
    final logsAsync = ref.watch(voiceLogsForEntityProvider(entity.id));
    final actionsAsync = ref.watch(actionItemsForEntityProvider(entity.id));
    final summaryAsync = ref.watch(entitySummaryForEntityProvider(entity.id));

    return Scaffold(
      appBar: AppBar(
        title: Text(
          entity.displayName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          _Header(entity: entity, labels: labels),
          SizedBox(height: 20.h),
          _SectionTitle(labels.context),
          _SummaryCard(
            summary: summaryAsync.value,
            fallbackText: 'Building a summary from your logs…',
          ),
          _StructuredFactsBlock(summary: summaryAsync.value),
          SizedBox(height: 20.h),
          if (entity.type.toUpperCase() == 'PROJECT')
            ..._decisionsSection(theme, actionsAsync, labels),
          _SectionTitle(labels.openTasks),
          _ActionList(
            actionsAsync: actionsAsync,
            includeTypes: _openTaskTypesFor(entity.type),
          ),
          SizedBox(height: 20.h),
          _SectionTitle(labels.conversations),
          _LogList(logsAsync: logsAsync),
        ],
      ),
    );
  }

  List<Widget> _decisionsSection(
    ThemeData theme,
    AsyncValue<List<VoiceActionItemView>> actionsAsync,
    _SectionLabels labels,
  ) {
    return [
      _SectionTitle(labels.decisions ?? 'Decisions'),
      _ActionList(
        actionsAsync: actionsAsync,
        includeTypes: const {VoiceActionType.decision},
        emptyHint: 'No decisions captured yet.',
      ),
      SizedBox(height: 20.h),
    ];
  }

  Set<VoiceActionType> _openTaskTypesFor(String entityType) {
    // For projects, decisions get their own section above, so the
    // "Open tasks" block only shows actionable items.
    if (entityType.toUpperCase() == 'PROJECT') {
      return {
        VoiceActionType.task,
        VoiceActionType.reminder,
        VoiceActionType.followUp,
      };
    }
    return {
      VoiceActionType.task,
      VoiceActionType.reminder,
      VoiceActionType.decision,
      VoiceActionType.followUp,
    };
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.entity, required this.labels});

  final CanonicalEntityView entity;
  final _SectionLabels labels;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Row(
      children: [
        CircleAvatar(
          radius: 28.r,
          backgroundColor: scheme.primaryContainer,
          child: Text(
            _avatarText(entity.displayName),
            style: theme.textTheme.titleLarge?.copyWith(
              color: scheme.onPrimaryContainer,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        SizedBox(width: 14.w),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                entity.displayName,
                style: theme.textTheme.titleLarge,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              SizedBox(height: 4.h),
              Row(
                children: [
                  Chip(
                    label: Text(labels.typeLabel),
                    visualDensity: VisualDensity.compact,
                  ),
                  SizedBox(width: 8.w),
                  Text(
                    '${entity.mentionCount} mention${entity.mentionCount == 1 ? '' : 's'}',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  String _avatarText(String name) {
    final parts = name
        .split(RegExp(r'\s+'))
        .where((p) => p.isNotEmpty)
        .toList(growable: false);
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
    return (parts.first.substring(0, 1) + parts.last.substring(0, 1))
        .toUpperCase();
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: 8.h),
      child: Text(
        text.toUpperCase(),
        style: theme.textTheme.labelMedium?.copyWith(
          fontWeight: FontWeight.w700,
          letterSpacing: 0.6,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.summary, required this.fallbackText});

  final EntitySummaryView? summary;
  final String fallbackText;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = summary?.summaryText.trim();
    final hasText = text != null && text.isNotEmpty;
    return Card(
      elevation: 0,
      color: theme.colorScheme.surfaceContainerHighest,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14.r)),
      child: Padding(
        padding: EdgeInsets.all(14.r),
        child: Text(
          hasText ? text : fallbackText,
          style: theme.textTheme.bodyMedium?.copyWith(
            height: 1.45.h,
            color: hasText
                ? theme.colorScheme.onSurface
                : theme.colorScheme.onSurfaceVariant,
            fontStyle: hasText ? FontStyle.normal : FontStyle.italic,
          ),
        ),
      ),
    );
  }
}

/// Renders the structured-fact dossier under the summary card. Hidden
/// when no facts have been generated yet (legacy summaries, or the
/// fallback path) so we don't show an empty section.
class _StructuredFactsBlock extends StatelessWidget {
  const _StructuredFactsBlock({required this.summary});

  final EntitySummaryView? summary;

  @override
  Widget build(BuildContext context) {
    final facts = summary?.structuredFacts;
    if (facts == null || facts.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final inlineLines = <Widget>[
      if (facts.relationship != null && facts.relationship!.isNotEmpty)
        _InlineMeta(label: 'Relationship', value: facts.relationship!),
      if (facts.status != null && facts.status!.isNotEmpty)
        _InlineMeta(label: 'Status', value: facts.status!),
    ];

    return Padding(
      padding: EdgeInsets.only(top: 10.h),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (inlineLines.isNotEmpty) ...[
            ...inlineLines,
            SizedBox(height: 8.h),
          ],
          if (facts.keyFacts.isNotEmpty) ...[
            Text(
              'Key facts',
              style: theme.textTheme.labelSmall?.copyWith(
                fontWeight: FontWeight.w700,
                color: scheme.onSurfaceVariant,
                letterSpacing: 0.5,
              ),
            ),
            SizedBox(height: 4.h),
            for (final fact in facts.keyFacts)
              Padding(
                padding: EdgeInsets.only(bottom: 2.h),
                child: Text(
                  '• $fact',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurface,
                    height: 1.35.h,
                  ),
                ),
              ),
            SizedBox(height: 8.h),
          ],
          if (facts.recentThemes.isNotEmpty)
            Wrap(
              spacing: 6,
              runSpacing: -6,
              children: [
                for (final theme0 in facts.recentThemes)
                  Chip(
                    label: Text(theme0),
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

class _InlineMeta extends StatelessWidget {
  const _InlineMeta({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: 2.h),
      child: RichText(
        text: TextSpan(
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurface,
          ),
          children: [
            TextSpan(
              text: '$label: ',
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            TextSpan(text: value),
          ],
        ),
      ),
    );
  }
}

class _LogList extends StatelessWidget {
  const _LogList({required this.logsAsync});
  final AsyncValue<List<VoiceLogView>> logsAsync;

  @override
  Widget build(BuildContext context) {
    return logsAsync.when(
      data: (logs) {
        if (logs.isEmpty) {
          return const _EmptyHint('No conversations yet.');
        }
        return Column(
          children: [for (final log in logs.take(20)) _LogTile(log: log)],
        );
      },
      loading: () => Padding(
        padding: EdgeInsets.symmetric(vertical: 12.h),
        child: const LinearProgressIndicator(),
      ),
      error: (e, _) => Text('Error: $e'),
    );
  }
}

class _LogTile extends StatelessWidget {
  const _LogTile({required this.log});
  final VoiceLogView log;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final title = _firstLine(log.displayTitle);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(
        title.isEmpty ? '(untitled log)' : title,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        _shortDate(log.createdAt),
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => LogDetailScreen(logId: log.id)),
      ),
    );
  }

  String _firstLine(String text) {
    final idx = text.indexOf('\n');
    return (idx >= 0 ? text.substring(0, idx) : text).trim();
  }

  String _shortDate(DateTime when) {
    final now = DateTime.now();
    final sameDay =
        when.year == now.year && when.month == now.month && when.day == now.day;
    final h = when.hour.toString().padLeft(2, '0');
    final m = when.minute.toString().padLeft(2, '0');
    if (sameDay) return 'Today $h:$m';
    return '${when.month}/${when.day}  $h:$m';
  }
}

class _ActionList extends StatelessWidget {
  const _ActionList({
    required this.actionsAsync,
    required this.includeTypes,
    this.emptyHint = 'No open items.',
  });

  final AsyncValue<List<VoiceActionItemView>> actionsAsync;
  final Set<VoiceActionType> includeTypes;
  final String emptyHint;

  @override
  Widget build(BuildContext context) {
    return actionsAsync.when(
      data: (items) {
        final filtered = items
            .where((a) => includeTypes.contains(a.type))
            .toList(growable: false);
        if (filtered.isEmpty) return _EmptyHint(emptyHint);
        return Column(
          children: [
            for (final action in filtered.take(20)) _ActionTile(action: action),
          ],
        );
      },
      loading: () => Padding(
        padding: EdgeInsets.symmetric(vertical: 12.h),
        child: const LinearProgressIndicator(),
      ),
      error: (e, _) => Text('Error: $e'),
    );
  }
}

class _ActionTile extends StatelessWidget {
  const _ActionTile({required this.action});
  final VoiceActionItemView action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final done = action.status == VoiceActionStatus.done;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        done ? Icons.check_circle : Icons.radio_button_unchecked,
        color: done
            ? theme.colorScheme.primary
            : theme.colorScheme.onSurfaceVariant,
      ),
      title: Text(
        action.title,
        style: TextStyle(
          decoration: done ? TextDecoration.lineThrough : null,
          color: done
              ? theme.colorScheme.onSurfaceVariant
              : theme.colorScheme.onSurface,
        ),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: action.dueAt == null
          ? null
          : Text(
              'Due ${_shortDate(action.dueAt!)}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => LogDetailScreen(logId: action.voiceLogId),
        ),
      ),
    );
  }

  String _shortDate(DateTime when) {
    return '${when.month}/${when.day}';
  }
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.symmetric(vertical: 4.h),
      child: Text(
        text,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          fontStyle: FontStyle.italic,
        ),
      ),
    );
  }
}

/// Section copy adapter — keeps the underlying widgets identical and just
/// swaps the human-readable labels by canonical entity type.
class _SectionLabels {
  _SectionLabels({
    required this.typeLabel,
    required this.conversations,
    required this.openTasks,
    required this.context,
    this.decisions,
  });

  final String typeLabel;
  final String conversations;
  final String openTasks;
  final String context;
  final String? decisions;

  factory _SectionLabels.forType(String type) {
    switch (type.toUpperCase()) {
      case 'PERSON':
        return _SectionLabels(
          typeLabel: 'Person',
          conversations: 'Conversations',
          openTasks: 'Open tasks',
          context: 'About',
        );
      case 'PROJECT':
        return _SectionLabels(
          typeLabel: 'Project',
          conversations: 'Timeline',
          openTasks: 'Open tasks',
          context: 'Recent updates',
          decisions: 'Decisions',
        );
      case 'PLACE':
        return _SectionLabels(
          typeLabel: 'Place',
          conversations: 'Visits',
          openTasks: 'Related tasks',
          context: 'About',
        );
      default:
        return _SectionLabels(
          typeLabel: type[0].toUpperCase() + type.substring(1).toLowerCase(),
          conversations: 'Mentions',
          openTasks: 'Related tasks',
          context: 'Context',
        );
    }
  }
}

/// One-shot lookup of a canonical entity by id. The page also subscribes to
/// the various stream providers above for live updates; this one only feeds
/// the header.
final _entityByIdProvider = FutureProvider.family
    .autoDispose<CanonicalEntityView?, String>((ref, id) {
      final repo = ref.watch(canonicalEntityRepositoryProvider);
      return repo.find(id);
    });
