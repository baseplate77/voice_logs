import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Coarse buckets the entity facet UI exposes. Maps onto the `type`
/// column of `canonical_entities`. Anything outside these three is
/// reachable through the global text query, not the facet bar.
enum EntityFacet { person, place, project }

extension EntityFacetLabel on EntityFacet {
  String get label => switch (this) {
    EntityFacet.person => 'People',
    EntityFacet.place => 'Places',
    EntityFacet.project => 'Projects',
  };

  /// Canonical-entity `type` strings produced by the refine pipeline.
  /// Multiple raw labels can map to one facet (e.g. `organization` is
  /// treated as a project for filtering purposes here).
  Set<String> get canonicalTypes => switch (this) {
    EntityFacet.person => const {'person', 'people'},
    EntityFacet.place => const {'place', 'location', 'venue'},
    EntityFacet.project => const {'project', 'organization', 'topic'},
  };
}

/// A timestamp window applied to `voice_logs.createdAt`. Both ends are
/// inclusive; either can be null for an open range.
class DateRange {
  const DateRange({this.start, this.end});

  final DateTime? start;
  final DateTime? end;

  bool get isUnbounded => start == null && end == null;
}

/// User-selected filters for the search screen. Composition rule:
/// AND across [EntityFacet] groups, OR within each group. Date range
/// and the action-items toggle further narrow the candidate set.
class SearchFilters {
  const SearchFilters({
    this.entityIdsByFacet = const {},
    this.dateRange = const DateRange(),
    this.requireActionItems = false,
  });

  /// Selected canonical entity IDs, grouped by the facet they came from.
  /// An entry's value is the disjunction (OR); the cross-facet join is
  /// AND. Empty map = no entity constraint.
  final Map<EntityFacet, Set<String>> entityIdsByFacet;

  final DateRange dateRange;

  /// When true, restrict to logs that have at least one row in
  /// `action_items`.
  final bool requireActionItems;

  bool get isEmpty =>
      entityIdsByFacet.values.every((s) => s.isEmpty) &&
      dateRange.isUnbounded &&
      !requireActionItems;

  /// Total entity chips currently selected across all facets — useful
  /// for the facet-bar badge.
  int get totalEntityChips =>
      entityIdsByFacet.values.fold(0, (acc, s) => acc + s.length);

  SearchFilters copyWith({
    Map<EntityFacet, Set<String>>? entityIdsByFacet,
    DateRange? dateRange,
    bool? requireActionItems,
  }) => SearchFilters(
    entityIdsByFacet: entityIdsByFacet ?? this.entityIdsByFacet,
    dateRange: dateRange ?? this.dateRange,
    requireActionItems: requireActionItems ?? this.requireActionItems,
  );

  SearchFilters toggleEntity(EntityFacet facet, String entityId) {
    final current = Map<EntityFacet, Set<String>>.from(entityIdsByFacet);
    final set = Set<String>.from(current[facet] ?? const <String>{});
    if (!set.add(entityId)) set.remove(entityId);
    if (set.isEmpty) {
      current.remove(facet);
    } else {
      current[facet] = set;
    }
    return copyWith(entityIdsByFacet: current);
  }

  SearchFilters clear() => const SearchFilters();
}

class SearchFiltersNotifier extends StateNotifier<SearchFilters> {
  SearchFiltersNotifier() : super(const SearchFilters());

  void toggleEntity(EntityFacet facet, String entityId) {
    state = state.toggleEntity(facet, entityId);
  }

  void setDateRange(DateRange range) {
    state = state.copyWith(dateRange: range);
  }

  void setRequireActionItems(bool value) {
    state = state.copyWith(requireActionItems: value);
  }

  void clear() {
    state = state.clear();
  }
}

final searchFiltersProvider =
    StateNotifierProvider<SearchFiltersNotifier, SearchFilters>(
      (_) => SearchFiltersNotifier(),
    );
