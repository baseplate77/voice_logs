import 'package:flutter_test/flutter_test.dart';
import 'package:voxsynth/retrieve/time_decay.dart';

void main() {
  group('timeDecayFactor', () {
    test('age 0 → 1.0 (no decay yet)', () {
      expect(
        timeDecayFactor(ageDays: 0, halfLifeDays: 30),
        closeTo(1.0, 1e-9),
      );
    });

    test('age == halfLife → 0.5', () {
      expect(
        timeDecayFactor(ageDays: 30, halfLifeDays: 30),
        closeTo(0.5, 1e-9),
      );
    });

    test('age == 2 × halfLife → 0.25', () {
      expect(
        timeDecayFactor(ageDays: 60, halfLifeDays: 30),
        closeTo(0.25, 1e-9),
      );
    });

    test('age == 3 × halfLife → 0.125', () {
      expect(
        timeDecayFactor(ageDays: 90, halfLifeDays: 30),
        closeTo(0.125, 1e-9),
      );
    });

    test('monotonically decreasing in age', () {
      double prev = timeDecayFactor(ageDays: 0, halfLifeDays: 30);
      for (var d = 1; d <= 365; d++) {
        final now = timeDecayFactor(
          ageDays: d.toDouble(),
          halfLifeDays: 30,
        );
        expect(now, lessThan(prev));
        prev = now;
      }
    });

    test('negative age is clamped to 0 (no boost for future chunks)',
        () {
      final neg =
          timeDecayFactor(ageDays: -5, halfLifeDays: 30);
      final zero = timeDecayFactor(ageDays: 0, halfLifeDays: 30);
      expect(neg, zero);
    });

    test('zero or negative half-life returns 1.0 (no decay)', () {
      expect(timeDecayFactor(ageDays: 10, halfLifeDays: 0), 1.0);
      expect(timeDecayFactor(ageDays: 10, halfLifeDays: -5), 1.0);
    });

    test('fractional ages work correctly (within half-life)', () {
      // At half of a half-life, factor = 2^-0.5 ≈ 0.707.
      expect(
        timeDecayFactor(ageDays: 15, halfLifeDays: 30),
        closeTo(0.7071, 1e-3),
      );
    });

    test('different half-lives produce different decay rates', () {
      final fast = timeDecayFactor(ageDays: 7, halfLifeDays: 7);
      final slow = timeDecayFactor(ageDays: 7, halfLifeDays: 90);
      expect(fast, closeTo(0.5, 1e-9));
      expect(slow, greaterThan(0.9));
    });
  });

  group('timeDecayBetween', () {
    test('identical instants yield 1.0', () {
      final t = DateTime.utc(2026, 4, 19, 12);
      expect(
        timeDecayBetween(now: t, createdAt: t, halfLifeDays: 30),
        closeTo(1.0, 1e-9),
      );
    });

    test('created-in-the-future clamps to 1.0', () {
      final now = DateTime.utc(2026, 4, 19, 12);
      final future = DateTime.utc(2026, 4, 20, 12);
      expect(
        timeDecayBetween(now: now, createdAt: future, halfLifeDays: 30),
        closeTo(1.0, 1e-9),
      );
    });

    test('30 days ago with 30-day half-life → ~0.5', () {
      final now = DateTime.utc(2026, 5, 19, 12);
      final thirtyAgo = DateTime.utc(2026, 4, 19, 12);
      expect(
        timeDecayBetween(
          now: now,
          createdAt: thirtyAgo,
          halfLifeDays: 30,
        ),
        closeTo(0.5, 1e-6),
      );
    });

    test('older entries decay more than newer ones', () {
      final now = DateTime.utc(2026, 5, 19, 12);
      final oneDayAgo = now.subtract(const Duration(days: 1));
      final tenDaysAgo = now.subtract(const Duration(days: 10));
      final hundredDaysAgo = now.subtract(const Duration(days: 100));

      final a = timeDecayBetween(
        now: now,
        createdAt: oneDayAgo,
        halfLifeDays: 30,
      );
      final b = timeDecayBetween(
        now: now,
        createdAt: tenDaysAgo,
        halfLifeDays: 30,
      );
      final c = timeDecayBetween(
        now: now,
        createdAt: hundredDaysAgo,
        halfLifeDays: 30,
      );
      expect(a, greaterThan(b));
      expect(b, greaterThan(c));
    });
  });
}
