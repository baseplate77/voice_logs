import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/db/providers.dart';
import '../../core/db/repositories/canonical_entity_repository.dart';
import 'search_filters.dart';

/// Canonical entities partitioned by [EntityFacet] for the facet picker.
/// Entries are mention-count descending within each facet.
class FacetedEntities {
  const FacetedEntities(this.byFacet);

  final Map<EntityFacet, List<CanonicalEntityView>> byFacet;

  List<CanonicalEntityView> forFacet(EntityFacet facet) =>
      byFacet[facet] ?? const [];

  bool get isEmpty => byFacet.values.every((l) => l.isEmpty);
}

/// Streams canonical entities and buckets them into the facet groups the
/// search UI cares about. Entities whose `type` falls outside the known
/// canonicalTypes mappings are dropped — they still surface via free-text
/// search, just not as a facet chip.
final facetedEntitiesProvider = StreamProvider<FacetedEntities>((ref) {
  final repo = ref.watch(canonicalEntityRepositoryProvider);
  return repo.watchAll().map((all) {
    final result = <EntityFacet, List<CanonicalEntityView>>{};
    for (final facet in EntityFacet.values) {
      final types = facet.canonicalTypes;
      result[facet] = all
          .where((e) => types.contains(e.type.toLowerCase()))
          .toList();
    }
    return FacetedEntities(result);
  });
});
