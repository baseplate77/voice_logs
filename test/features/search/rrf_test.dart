import 'package:flutter_test/flutter_test.dart';
import 'package:voxsynth/features/search/rrf.dart';

void main() {
  test('RRF combines ranked lists favoring consistent top hits', () {
    final a = ['x', 'y', 'z'];
    final b = ['y', 'x', 'w'];
    final c = ['x', 'w', 'v'];
    final scores = reciprocalRankFusion(rankedLists: [a, b, c]);

    // 'x' appears in all three and top-2 in each — should rank first.
    final ordered = sortByScoreDescending(scores);
    expect(ordered.first, 'x');
    expect(ordered.contains('y'), isTrue);
  });

  test('absent items have no score', () {
    final scores = reciprocalRankFusion(
      rankedLists: [
        ['a', 'b'],
        ['b', 'c'],
      ],
    );
    expect(scores.containsKey('zzz'), isFalse);
    expect(scores['b']! > scores['a']!, isTrue);
  });

  test('empty input yields empty scores', () {
    expect(reciprocalRankFusion(rankedLists: const []), isEmpty);
    expect(reciprocalRankFusion(rankedLists: [const []]), isEmpty);
  });
}
