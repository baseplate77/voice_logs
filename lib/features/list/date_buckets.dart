import '../../core/db/repositories/voice_log_repository.dart';

/// A contiguous run of logs that share a date bucket (Today, Yesterday,
/// This Week, or a specific month).
class LogDateGroup {
  const LogDateGroup({required this.label, required this.logs});

  final String label;
  final List<VoiceLogView> logs;
}

/// Splits logs (already sorted newest-first) into labelled date buckets:
///   • TODAY
///   • YESTERDAY
///   • THIS WEEK (2–6 days ago)
///   • `<MONTH YEAR>` (e.g. "MAY 2026") for anything older
///
/// [now] is injectable for tests; defaults to `DateTime.now()`.
List<LogDateGroup> groupLogsByDate(List<VoiceLogView> logs, {DateTime? now}) {
  if (logs.isEmpty) return const [];

  final reference = now ?? DateTime.now();
  final today = DateTime(reference.year, reference.month, reference.day);
  final yesterday = today.subtract(const Duration(days: 1));
  final weekStart = today.subtract(const Duration(days: 6));

  final groups = <String, List<VoiceLogView>>{};
  final order = <String>[];

  for (final log in logs) {
    final created = log.createdAt;
    final createdDay = DateTime(created.year, created.month, created.day);
    final label = _labelFor(
      createdDay: createdDay,
      today: today,
      yesterday: yesterday,
      weekStart: weekStart,
    );
    final bucket = groups.putIfAbsent(label, () {
      order.add(label);
      return <VoiceLogView>[];
    });
    bucket.add(log);
  }

  return [
    for (final label in order) LogDateGroup(label: label, logs: groups[label]!),
  ];
}

String _labelFor({
  required DateTime createdDay,
  required DateTime today,
  required DateTime yesterday,
  required DateTime weekStart,
}) {
  if (createdDay == today) return 'TODAY';
  if (createdDay == yesterday) return 'YESTERDAY';
  if (!createdDay.isBefore(weekStart) && createdDay.isBefore(yesterday)) {
    return 'THIS WEEK';
  }
  return '${_monthName(createdDay.month)} ${createdDay.year}';
}

const _months = [
  'JAN',
  'FEB',
  'MAR',
  'APR',
  'MAY',
  'JUN',
  'JUL',
  'AUG',
  'SEP',
  'OCT',
  'NOV',
  'DEC',
];

String _monthName(int month) => _months[month - 1];
