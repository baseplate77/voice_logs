import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../core/db/providers.dart';
import '../../core/db/repositories/canonical_entity_repository.dart';
import '../../core/result.dart';
import '../../core/worker/providers.dart';
import '../detail/log_detail_screen.dart';
import '../entity/entity_detail_screen.dart';
import 'entity_facet_provider.dart';
import 'hybrid_retriever.dart';
import 'search_filters.dart';

/// Hybrid search screen. FTS works immediately on raw transcripts;
/// embedded logs also participate in vector search after background
/// refinement/embedding finishes. The facet bar lets the user narrow
/// to specific people/places/projects, a date range, or just logs that
/// produced action items.
class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final _controller = TextEditingController();
  Timer? _debounce;
  String _query = '';

  @override
  void dispose() {
    _controller.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  void _onChanged(String raw) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 200), () {
      if (!mounted) return;
      setState(() => _query = raw.trim());
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _controller,
          autofocus: true,
          textInputAction: TextInputAction.search,
          decoration: const InputDecoration(
            hintText: 'Search your journal…',
            border: InputBorder.none,
          ),
          onChanged: _onChanged,
        ),
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(48),
          child: _FilterBar(),
        ),
      ),
      body: _query.isEmpty
          ? const _EmptyPrompt()
          : _SearchResults(query: _query),
    );
  }
}

class _EmptyPrompt extends StatelessWidget {
  const _EmptyPrompt();

  @override
  Widget build(BuildContext context) => const Center(
    child: Text('Type to search raw transcripts, cleaned text, entities.'),
  );
}

class _SearchResults extends ConsumerWidget {
  const _SearchResults({required this.query});
  final String query;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filters = ref.watch(searchFiltersProvider);
    final hitsAsync = ref.watch(
      _hybridSearchProvider((query: query, filters: filters)),
    );
    return hitsAsync.when(
      data: (rows) {
        if (rows.isEmpty) {
          return const Center(child: Text('No matches.'));
        }
        return ListView.separated(
          itemCount: rows.length,
          separatorBuilder: (_, _) => Divider(height: 1.h),
          itemBuilder: (_, i) => _ResultTile(hit: rows[i], query: query),
        );
      },
      loading: () => const Center(child: CircularProgressIndicator.adaptive()),
      error: (e, _) => Center(child: Text('Error: $e')),
    );
  }
}

class _ResultTile extends StatelessWidget {
  const _ResultTile({required this.hit, required this.query});

  final SearchHit hit;
  final String query;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      title: Text.rich(
        _highlightedSnippetSpan(context, hit.snippet, query),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (hit.localReason.isNotEmpty)
            Padding(
              padding: EdgeInsets.only(top: 2.h),
              child: Text(
                hit.localReason,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.primary,
                ),
              ),
            ),
          Padding(
            padding: EdgeInsets.only(top: 2.h),
            child: Text(
              _sourceLabel(hit.matchedVia),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => LogDetailScreen(
            logId: hit.logId,
            initialSeekMs: hit.bestSegmentStartMs,
            highlightStartMs: hit.bestSegmentStartMs,
            highlightEndMs: hit.bestSegmentEndMs,
          ),
        ),
      ),
    );
  }
}

class _FilterBar extends ConsumerWidget {
  const _FilterBar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filters = ref.watch(searchFiltersProvider);
    final notifier = ref.read(searchFiltersProvider.notifier);
    final facetedAsync = ref.watch(facetedEntitiesProvider);
    return SizedBox(
      height: 48.h,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.symmetric(horizontal: 12.w),
        children: [
          for (final facet in EntityFacet.values)
            Padding(
              padding: EdgeInsets.only(right: 8.w),
              child: _EntityFacetChip(
                facet: facet,
                selectedCount: filters.entityIdsByFacet[facet]?.length ?? 0,
                disabled: facetedAsync.maybeWhen(
                  data: (f) => f.forFacet(facet).isEmpty,
                  orElse: () => true,
                ),
                onTap: () => _openEntitySheet(context, ref, facet),
              ),
            ),
          Padding(
            padding: EdgeInsets.only(right: 8.w),
            child: _DateRangeChip(
              range: filters.dateRange,
              onPick: notifier.setDateRange,
            ),
          ),
          Padding(
            padding: EdgeInsets.only(right: 8.w),
            child: FilterChip(
              label: const Text('Tasks'),
              selected: filters.requireActionItems,
              onSelected: notifier.setRequireActionItems,
            ),
          ),
          if (!filters.isEmpty)
            TextButton(onPressed: notifier.clear, child: const Text('Clear')),
        ],
      ),
    );
  }

  Future<void> _openEntitySheet(
    BuildContext context,
    WidgetRef ref,
    EntityFacet facet,
  ) async {
    final facetedAsync = ref.read(facetedEntitiesProvider);
    final entities = facetedAsync.maybeWhen(
      data: (f) => f.forFacet(facet),
      orElse: () => <CanonicalEntityView>[],
    );
    if (entities.isEmpty) return;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (_) => _EntityPickerSheet(facet: facet, entities: entities),
    );
  }
}

class _EntityFacetChip extends StatelessWidget {
  const _EntityFacetChip({
    required this.facet,
    required this.selectedCount,
    required this.disabled,
    required this.onTap,
  });

  final EntityFacet facet;
  final int selectedCount;
  final bool disabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final label = selectedCount > 0
        ? '${facet.label} ($selectedCount)'
        : facet.label;
    return InputChip(
      label: Text(label),
      selected: selectedCount > 0,
      onPressed: disabled ? null : onTap,
      avatar: Icon(Icons.filter_list, size: 18.r),
    );
  }
}

class _EntityPickerSheet extends ConsumerWidget {
  const _EntityPickerSheet({required this.facet, required this.entities});

  final EntityFacet facet;
  final List<CanonicalEntityView> entities;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filters = ref.watch(searchFiltersProvider);
    final notifier = ref.read(searchFiltersProvider.notifier);
    final selected = filters.entityIdsByFacet[facet] ?? <String>{};
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(facet.label, style: Theme.of(context).textTheme.titleMedium),
            SizedBox(height: 8.h),
            // Each chip is a filter toggle; the trailing arrow button on
            // the right opens the entity detail page directly without
            // toggling the filter. Keeps the primary action (filter) on
            // the chip itself and the navigation as an explicit affordance.
            for (final e in entities)
              Padding(
                padding: EdgeInsets.only(bottom: 4.h),
                child: Row(
                  children: [
                    Expanded(
                      child: FilterChip(
                        label: Text(e.displayName),
                        selected: selected.contains(e.id),
                        onSelected: (_) => notifier.toggleEntity(facet, e.id),
                      ),
                    ),
                    IconButton(
                      icon: Icon(Icons.arrow_forward, size: 18.r),
                      tooltip: 'Open ${e.displayName}',
                      onPressed: () {
                        Navigator.of(context).pop();
                        Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => EntityDetailScreen(entityId: e.id),
                          ),
                        );
                      },
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _DateRangeChip extends StatelessWidget {
  const _DateRangeChip({required this.range, required this.onPick});

  final DateRange range;
  final ValueChanged<DateRange> onPick;

  @override
  Widget build(BuildContext context) {
    final label = _labelFor(range);
    return InputChip(
      label: Text(label),
      selected: !range.isUnbounded,
      avatar: Icon(Icons.calendar_today_outlined, size: 16.r),
      onPressed: () => _openMenu(context),
    );
  }

  Future<void> _openMenu(BuildContext context) async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final selected = await showMenu<DateRange>(
      context: context,
      position: const RelativeRect.fromLTRB(16, 96, 16, 0),
      items: [
        const PopupMenuItem(value: DateRange(), child: Text('Any time')),
        PopupMenuItem(
          value: DateRange(start: today),
          child: const Text('Today'),
        ),
        PopupMenuItem(
          value: DateRange(start: today.subtract(const Duration(days: 7))),
          child: const Text('Last 7 days'),
        ),
        PopupMenuItem(
          value: DateRange(start: today.subtract(const Duration(days: 30))),
          child: const Text('Last 30 days'),
        ),
      ],
    );
    if (selected != null) onPick(selected);
  }

  static String _labelFor(DateRange range) {
    if (range.isUnbounded) return 'Date';
    final start = range.start;
    if (start == null) return 'Date';
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final days = today.difference(start).inDays;
    if (days == 0) return 'Today';
    if (days <= 7) return 'Last 7d';
    if (days <= 30) return 'Last 30d';
    return '${start.year}-${start.month.toString().padLeft(2, '0')}-'
        '${start.day.toString().padLeft(2, '0')}';
  }
}

TextSpan _highlightedSnippetSpan(
  BuildContext context,
  String snippet,
  String query,
) {
  final base = Theme.of(context).textTheme.bodyMedium;
  final isDark = Theme.of(context).brightness == Brightness.dark;
  final highlightStyle = (base ?? const TextStyle()).copyWith(
    backgroundColor: isDark ? const Color(0xFF8C6D00) : const Color(0xFFFFF59D),
    color: isDark ? Colors.white : Colors.black,
    fontWeight: FontWeight.w700,
  );
  final terms = _highlightTerms(query);
  if (snippet.isEmpty || terms.isEmpty) {
    return TextSpan(text: snippet, style: base);
  }

  final pattern = terms.map(RegExp.escape).join('|');
  final matches = RegExp(pattern, caseSensitive: false).allMatches(snippet);
  final children = <TextSpan>[];
  var cursor = 0;
  for (final match in matches) {
    if (match.start < cursor) continue;
    if (match.start > cursor) {
      children.add(TextSpan(text: snippet.substring(cursor, match.start)));
    }
    children.add(
      TextSpan(
        text: snippet.substring(match.start, match.end),
        style: highlightStyle,
      ),
    );
    cursor = match.end;
  }
  if (cursor < snippet.length) {
    children.add(TextSpan(text: snippet.substring(cursor)));
  }
  return TextSpan(style: base, children: children);
}

List<String> _highlightTerms(String query) {
  final seen = <String>{};
  final terms = query
      .toLowerCase()
      .split(RegExp(r'\W+'))
      .where((w) => w.length > 1)
      .where(seen.add)
      .toList();
  terms.sort((a, b) => b.length.compareTo(a.length));
  return terms;
}

String _sourceLabel(Set<MatchSource> sources) {
  if (sources.isEmpty) return 'keyword';
  final labels = sources
      .map((s) {
        return switch (s) {
          MatchSource.fts => 'keyword',
          MatchSource.vector => 'semantic',
          MatchSource.entity => 'entity',
        };
      })
      .join(' + ');
  return labels;
}

typedef _SearchArgs = ({String query, SearchFilters filters});

final _hybridSearchProvider =
    FutureProvider.family<List<SearchHit>, _SearchArgs>((ref, args) async {
      final vecStore = ref.watch(vecStoreProvider);
      await vecStore.load();
      final retriever = HybridRetriever(
        db: ref.watch(voxSynthDatabaseProvider),
        embedder: ref.watch(embedderProvider),
        vecStore: vecStore,
      );
      final res = await retriever.search(
        args.query,
        limit: 20,
        filters: args.filters,
      );
      return switch (res) {
        Ok(:final value) => value,
        Err(:final error) => throw StateError(error.message),
      };
    });
