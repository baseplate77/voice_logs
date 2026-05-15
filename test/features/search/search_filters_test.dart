import 'package:flutter_test/flutter_test.dart';
import 'package:voxsynth/features/search/search_filters.dart';

void main() {
  group('SearchFilters', () {
    test('is empty by default', () {
      const f = SearchFilters();
      expect(f.isEmpty, isTrue);
      expect(f.totalEntityChips, 0);
    });

    test('toggleEntity adds then removes ids per facet', () {
      const start = SearchFilters();
      final a = start.toggleEntity(EntityFacet.person, 'e1');
      expect(a.entityIdsByFacet[EntityFacet.person], equals({'e1'}));
      expect(a.totalEntityChips, 1);
      final b = a.toggleEntity(EntityFacet.person, 'e1');
      expect(b.entityIdsByFacet.containsKey(EntityFacet.person), isFalse);
      expect(b.isEmpty, isTrue);
    });

    test('toggleEntity keeps facets independent', () {
      var f = const SearchFilters();
      f = f.toggleEntity(EntityFacet.person, 'p1');
      f = f.toggleEntity(EntityFacet.place, 'pl1');
      f = f.toggleEntity(EntityFacet.person, 'p2');
      expect(f.entityIdsByFacet[EntityFacet.person], {'p1', 'p2'});
      expect(f.entityIdsByFacet[EntityFacet.place], {'pl1'});
      expect(f.totalEntityChips, 3);
    });

    test('clear resets every field', () {
      final f = const SearchFilters(requireActionItems: true)
          .toggleEntity(EntityFacet.project, 'proj1')
          .copyWith(dateRange: DateRange(start: DateTime(2026, 1, 2)));
      expect(f.isEmpty, isFalse);
      expect(f.clear().isEmpty, isTrue);
    });

    test('DateRange.isUnbounded only when both ends are null', () {
      expect(const DateRange().isUnbounded, isTrue);
      expect(DateRange(start: DateTime(2026, 2)).isUnbounded, isFalse);
      expect(DateRange(end: DateTime(2026, 2)).isUnbounded, isFalse);
    });

    test('EntityFacet canonical types cover expected raw labels', () {
      expect(EntityFacet.person.canonicalTypes, contains('person'));
      expect(EntityFacet.place.canonicalTypes, contains('location'));
      expect(EntityFacet.project.canonicalTypes, contains('organization'));
    });
  });
}
