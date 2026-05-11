import 'package:flutter_test/flutter_test.dart';
import 'package:voxsynth/features/enrich/importance_scorer.dart';

void main() {
  test('base score for neutral text', () {
    final score = computeImportance('I went for a walk today.');
    expect(score, closeTo(0.3, 0.01));
  });

  test('remember keyword boosts score', () {
    final score = computeImportance('Remember to call the dentist.');
    expect(score, greaterThanOrEqualTo(0.5));
  });

  test('decision keyword boosts score', () {
    final score = computeImportance('I decided to switch to Flutter.');
    expect(score, greaterThanOrEqualTo(0.55));
  });

  test('task keyword boosts score', () {
    final score = computeImportance('I need to finish the migration.');
    expect(score, greaterThanOrEqualTo(0.5));
  });

  test('goal and idea keywords boost score', () {
    final scoreGoal = computeImportance('My goal is to ship by June.');
    final scoreIdea = computeImportance('I had an idea for a new feature.');
    // 0.3 base + 0.15 goal/idea (+ 0.15 future time for "June")
    expect(scoreGoal, greaterThan(0.44));
    expect(scoreIdea, greaterThan(0.44));
  });

  test('future time reference boosts score', () {
    final score = computeImportance('The deadline is next week.');
    expect(score, greaterThanOrEqualTo(0.6));
  });

  test('emotion words boost score', () {
    final score = computeImportance('I am really frustrated with this bug.');
    expect(score, greaterThanOrEqualTo(0.4));
  });

  test('entity name match boosts score', () {
    final score = computeImportance(
      'Priya helped test the app.',
      entityNames: {'Priya'},
    );
    expect(score, greaterThanOrEqualTo(0.4));
  });

  test('repeated topic match boosts score', () {
    final score = computeImportance(
      'I worked on VoxSynth today.',
      repeatedTopics: {'voxsynth'},
    );
    expect(score, greaterThan(0.44));
  });

  test('multiple signals stack and cap at 1.0', () {
    final score = computeImportance(
      'Remember, I decided the important deadline is next week. '
      'I need to follow up. This is my goal and idea. I am excited.',
      entityNames: {'VoxSynth'},
      repeatedTopics: {'deadline'},
    );
    expect(score, equals(1.0));
  });

  test('empty text returns base score', () {
    final score = computeImportance('');
    expect(score, closeTo(0.3, 0.01));
  });
}
