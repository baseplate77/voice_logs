import 'package:freezed_annotation/freezed_annotation.dart';

part 'weekly_themes.freezed.dart';
part 'weekly_themes.g.dart';

/// Output schema for [WeeklyThemesJob] — a week-long roll-up of the
/// recurring topics + contradictions that surfaced across 7 days of
/// chunks. Round-trips through [SynthesisRecord.payloadJson].
@freezed
sealed class WeeklyThemes with _$WeeklyThemes {
  const factory WeeklyThemes({
    /// Monday of the week covered, `YYYY-MM-DD` in local tz.
    required String weekStart,

    /// 3–5 recurring themes the week kept returning to.
    required List<WeeklyTheme> themes,

    /// Stance shifts the user made during the week — pairs of "at some
    /// point you said X, later you said Y". Empty when the week was
    /// consistent.
    required List<WeeklyContradiction> contradictions,
  }) = _WeeklyThemes;

  factory WeeklyThemes.fromJson(Map<String, Object?> json) =>
      _$WeeklyThemesFromJson(json);
}

/// One recurring topic. `supportingChunkIds` carries all chunks that
/// contributed, not just the top exemplar, so the UI can offer a
/// "show all mentions" affordance.
@freezed
sealed class WeeklyTheme with _$WeeklyTheme {
  const factory WeeklyTheme({
    required String title,
    required String summary,
    required List<int> supportingChunkIds,
  }) = _WeeklyTheme;

  factory WeeklyTheme.fromJson(Map<String, Object?> json) =>
      _$WeeklyThemeFromJson(json);
}

/// A position that shifted during the week.
@freezed
sealed class WeeklyContradiction with _$WeeklyContradiction {
  const factory WeeklyContradiction({
    required String earlierPosition,
    required String laterPosition,
    required List<int> earlierChunkIds,
    required List<int> laterChunkIds,
  }) = _WeeklyContradiction;

  factory WeeklyContradiction.fromJson(Map<String, Object?> json) =>
      _$WeeklyContradictionFromJson(json);
}
