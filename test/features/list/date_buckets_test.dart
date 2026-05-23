import 'package:flutter_test/flutter_test.dart';
import 'package:voxsynth/core/db/processing_state.dart';
import 'package:voxsynth/core/db/repositories/voice_log_repository.dart';
import 'package:voxsynth/features/list/date_buckets.dart';

VoiceLogView _log(String id, DateTime at) => VoiceLogView(
  id: id,
  createdAt: at,
  durationMs: 0,
  audioPath: '',
  rawTranscript: '',
  cleanedText: null,
  title: null,
  processingState: ProcessingState.embedded,
  errorMessage: null,
);

void main() {
  final now = DateTime(2026, 5, 23, 14); // Saturday afternoon

  test('returns empty list for empty input', () {
    expect(groupLogsByDate([], now: now), isEmpty);
  });

  test('groups across TODAY, YESTERDAY, THIS WEEK, and month buckets', () {
    final logs = [
      _log('today_pm', DateTime(2026, 5, 23, 13)),
      _log('today_am', DateTime(2026, 5, 23, 8)),
      _log('yesterday', DateTime(2026, 5, 22, 20)),
      _log('three_days', DateTime(2026, 5, 20, 9)),
      _log('week_edge', DateTime(2026, 5, 17, 9)), // 6 days ago → THIS WEEK
      _log('week_over', DateTime(2026, 5, 16, 9)), // 7 days ago → MAY 2026
      _log('old', DateTime(2026, 3, 11, 9)),
    ];

    final groups = groupLogsByDate(logs, now: now);

    expect(groups.map((g) => g.label).toList(), [
      'TODAY',
      'YESTERDAY',
      'THIS WEEK',
      'MAY 2026',
      'MAR 2026',
    ]);
    expect(groups[0].logs.map((l) => l.id), ['today_pm', 'today_am']);
    expect(groups[1].logs.single.id, 'yesterday');
    expect(groups[2].logs.map((l) => l.id), ['three_days', 'week_edge']);
    expect(groups[3].logs.single.id, 'week_over');
    expect(groups[4].logs.single.id, 'old');
  });

  test('YESTERDAY does not bleed into THIS WEEK', () {
    final groups = groupLogsByDate([
      _log('y', DateTime(2026, 5, 22, 23, 59)),
    ], now: now);
    expect(groups.single.label, 'YESTERDAY');
  });

  test('logs older than a week of the same month land in MMM YYYY', () {
    final groups = groupLogsByDate([
      _log('a', DateTime(2026, 5, 1, 10)),
    ], now: now);
    expect(groups.single.label, 'MAY 2026');
  });

  test('preserves insertion order within a bucket', () {
    final logs = [
      _log('first', DateTime(2026, 5, 23, 18)),
      _log('second', DateTime(2026, 5, 23, 12)),
      _log('third', DateTime(2026, 5, 23, 8)),
    ];
    final groups = groupLogsByDate(logs, now: now);
    expect(groups.single.label, 'TODAY');
    expect(groups.single.logs.map((l) => l.id), ['first', 'second', 'third']);
  });
}
