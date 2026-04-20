import 'package:flutter_test/flutter_test.dart';
import 'package:voxsynth/retrieve/rrf.dart';

void main() {
  group('reciprocalRankFusion', () {
    test('empty input → empty output', () {
      expect(reciprocalRankFusion<int>(<List<int>>[]), isEmpty);
    });

    test('single list is a pass-through ordering', () {
      final r = reciprocalRankFusion<String>([
        <String>['a', 'b', 'c'],
      ]);
      expect(r, <String>['a', 'b', 'c']);
    });

    test('an item ranked first in both lists wins over one ranked '
        'first in only one', () {
      final r = reciprocalRankFusion<String>([
        <String>['alpha', 'beta', 'gamma'],
        <String>['alpha', 'delta', 'beta'],
      ]);
      expect(r.first, 'alpha');
    });

    test('fusion surfaces items missing from some lists', () {
      final r = reciprocalRankFusion<String>([
        <String>['a', 'b', 'c'],
        <String>['d', 'e', 'f'],
      ]);
      expect(r, containsAll(<String>['a', 'b', 'c', 'd', 'e', 'f']));
      expect(r.length, 6);
    });

    test('identical single-item lists are fused to just that item', () {
      final r = reciprocalRankFusion<int>([
        <int>[42],
        <int>[42],
        <int>[42],
      ]);
      expect(r, <int>[42]);
    });

    test('ranking that appears earlier in more lists scores higher', () {
      // 'x' is 1st, 1st, 2nd. 'y' is 2nd, 2nd, 1st. 'x' should win.
      final r = reciprocalRankFusion<String>([
        <String>['x', 'y'],
        <String>['x', 'y'],
        <String>['y', 'x'],
      ]);
      expect(r.first, 'x');
      expect(r.last, 'y');
    });

    test('smaller k gives sharper spread between top and bottom', () {
      // 'a' is 1st in both lists, 'b' is far down. Scores are
      // symmetric but the SPREAD between first and last scales
      // inversely with k.
      final list = [
        <String>['a', 'b'],
        <String>['a', 'b'],
      ];
      final tightK = reciprocalRankFusionScored(list, k: 0);
      final looseK = reciprocalRankFusionScored(list, k: 1000);
      final tightSpread =
          (tightK.values.first - tightK.values.last).abs();
      final looseSpread =
          (looseK.values.first - looseK.values.last).abs();
      expect(tightSpread, greaterThan(looseSpread));
    });

    test('duplicates within a single ranking count once', () {
      final r = reciprocalRankFusion<String>([
        <String>['a', 'a', 'a'], // only the first 'a' counts
        <String>['b'],
      ]);
      // 'a' scored 1/(60+1); 'b' scored 1/(60+1). Tie → insertion order.
      expect(r.first, 'a');
      expect(r.length, 2);
    });

    test('scored variant returns fused scores in sorted order', () {
      final scored = reciprocalRankFusionScored<String>([
        <String>['a', 'b'],
        <String>['a', 'c'],
      ]);
      final keys = scored.keys.toList();
      final values = scored.values.toList();
      expect(keys.first, 'a');
      // Scores strictly descending.
      for (var i = 0; i + 1 < values.length; i++) {
        expect(values[i], greaterThanOrEqualTo(values[i + 1]));
      }
    });
  });
}
