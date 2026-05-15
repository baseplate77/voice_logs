import 'package:flutter_test/flutter_test.dart';
import 'package:voxsynth/features/ask/ask_query_utils.dart';

void main() {
  test('buildAskRetrievalQuery strips wrapper and temporal phrases', () {
    expect(
      buildAskRetrievalQuery(
        'What did I say about the Atlas project last week?',
      ),
      'atlas project',
    );
  });

  test('inferAskSearchFilters maps last week to previous Monday-Sunday', () {
    final filters = inferAskSearchFilters(
      'What did I say about Atlas last week?',
      now: DateTime(2026, 5, 15, 12), // Friday.
    );

    expect(filters.dateRange.start, DateTime(2026, 5, 4));
    expect(filters.dateRange.end, DateTime(2026, 5, 10, 23, 59, 59, 999));
  });

  test('inferAskSearchFilters returns empty filter without time phrase', () {
    final filters = inferAskSearchFilters('What did I say about Atlas?');
    expect(filters.isEmpty, isTrue);
  });
}
