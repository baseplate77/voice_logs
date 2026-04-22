import 'package:freezed_annotation/freezed_annotation.dart';

part 'monthly_shifts.freezed.dart';
part 'monthly_shifts.g.dart';

/// Output schema for [MonthlyShiftsJob] — what's materially different
/// about this month vs the last 30 days prior, based on the chunks +
/// earlier syntheses.
@freezed
sealed class MonthlyShifts with _$MonthlyShifts {
  const factory MonthlyShifts({
    /// First day of the covered month, `YYYY-MM-DD` local.
    required String monthStart,

    /// One paragraph describing the headline shift. Never empty; job
    /// falls back to "No notable shifts this month." when appropriate.
    required String headline,

    /// Specific deltas the job identified. Empty when the month was
    /// quiet or indistinguishable from the prior one.
    required List<MonthlyShift> shifts,
  }) = _MonthlyShifts;

  factory MonthlyShifts.fromJson(Map<String, Object?> json) =>
      _$MonthlyShiftsFromJson(json);
}

/// One dimension along which things changed — a topic, a stance, a
/// recurring question. `priorChunkIds` / `currentChunkIds` point at the
/// source material on each side of the diff.
@freezed
sealed class MonthlyShift with _$MonthlyShift {
  const factory MonthlyShift({
    required String topic,
    required String priorSummary,
    required String currentSummary,
    required List<int> priorChunkIds,
    required List<int> currentChunkIds,
  }) = _MonthlyShift;

  factory MonthlyShift.fromJson(Map<String, Object?> json) =>
      _$MonthlyShiftFromJson(json);
}
