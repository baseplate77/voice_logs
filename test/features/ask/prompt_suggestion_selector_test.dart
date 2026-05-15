import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:voxsynth/core/db/repositories/prompt_suggestion_repository.dart';
import 'package:voxsynth/features/ask/prompt_suggestion_selector.dart';

PromptSuggestionView _view({
  required String id,
  required DateTime createdAt,
  int usedCount = 0,
  DateTime? lastUsedAt,
  String? chipText,
}) {
  return PromptSuggestionView(
    id: id,
    logId: 'log_$id',
    chipText: chipText ?? id,
    question: 'Question $id?',
    usedCount: usedCount,
    lastUsedAt: lastUsedAt,
    createdAt: createdAt,
  );
}

void main() {
  group('PromptSuggestionSelector', () {
    final now = DateTime(2026, 5, 15, 12);

    test('returns empty list for an empty pool', () {
      const selector = PromptSuggestionSelector();
      expect(selector.pick(const [], now: now), isEmpty);
    });

    test('caps output at limit', () {
      const selector = PromptSuggestionSelector();
      final pool = List.generate(
        10,
        (i) => _view(
          id: 'a$i',
          createdAt: now.subtract(Duration(days: i)),
        ),
      );
      final picked = selector.pick(pool, now: now, limit: 3, random: Random(1));
      expect(picked, hasLength(3));
    });

    test('prefers recent chips for the recent slots', () {
      const selector = PromptSuggestionSelector(
        randomSlots: 0,
        topUsedSlots: 0,
      );
      final pool = [
        _view(id: 'old1', createdAt: now.subtract(const Duration(days: 30))),
        _view(id: 'old2', createdAt: now.subtract(const Duration(days: 60))),
        _view(id: 'new1', createdAt: now.subtract(const Duration(hours: 2))),
        _view(id: 'new2', createdAt: now.subtract(const Duration(days: 1))),
      ];
      final picked = selector.pick(pool, now: now, limit: 2, random: Random(7));
      final ids = picked.map((s) => s.id).toSet();
      expect(ids, equals({'new1', 'new2'}));
    });

    test('top-used slot picks the chip with the highest used_count', () {
      const selector = PromptSuggestionSelector(recentSlots: 0, randomSlots: 0);
      final pool = [
        _view(
          id: 'rare',
          createdAt: now.subtract(const Duration(days: 60)),
          usedCount: 1,
        ),
        _view(
          id: 'popular',
          createdAt: now.subtract(const Duration(days: 90)),
          usedCount: 12,
          lastUsedAt: now,
        ),
        _view(id: 'fresh', createdAt: now.subtract(const Duration(hours: 6))),
      ];
      final picked = selector.pick(pool, now: now, random: Random(3));
      expect(picked.map((s) => s.id), contains('popular'));
    });

    test('top-used slot is skipped when nothing has been tapped yet', () {
      const selector = PromptSuggestionSelector(recentSlots: 0, randomSlots: 0);
      final pool = [
        _view(id: 'a', createdAt: now.subtract(const Duration(days: 30))),
        _view(id: 'b', createdAt: now.subtract(const Duration(days: 60))),
      ];
      final picked = selector.pick(pool, now: now, random: Random(0));
      // top-used contributed nothing because everything has used_count=0;
      // leftover-fill still surfaces both chips up to the limit.
      expect(picked, hasLength(2));
    });

    test('random-weighted shuffle favors low used_count over many trials', () {
      const selector = PromptSuggestionSelector(
        recentSlots: 0,
        randomSlots: 1,
        topUsedSlots: 0,
      );
      final pool = [
        _view(id: 'low', createdAt: now.subtract(const Duration(days: 200))),
        _view(
          id: 'high',
          createdAt: now.subtract(const Duration(days: 200)),
          usedCount: 50,
          lastUsedAt: now,
        ),
      ];

      var lowWins = 0;
      var highWins = 0;
      for (var seed = 0; seed < 500; seed++) {
        final picked = selector.pick(
          pool,
          now: now,
          limit: 1,
          random: Random(seed),
        );
        if (picked.first.id == 'low') {
          lowWins++;
        } else {
          highWins++;
        }
      }
      expect(lowWins, greaterThan(highWins * 3));
    });

    test('dedupes across slot kinds', () {
      const selector = PromptSuggestionSelector();
      final pool = [
        _view(
          id: 'overlap',
          createdAt: now.subtract(const Duration(hours: 1)),
          usedCount: 99,
          lastUsedAt: now,
        ),
        _view(id: 'b', createdAt: now.subtract(const Duration(days: 1))),
      ];
      final picked = selector.pick(pool, now: now, random: Random(11));
      // 'overlap' could qualify under recent + top-used + random — must still
      // appear at most once.
      expect(picked.where((s) => s.id == 'overlap'), hasLength(1));
    });
  });
}
