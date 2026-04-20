/// String constants shared by the `syntheses.kind` column, the
/// `WorkManager` job names, and the freezed payload types.
///
/// Kept as plain `const String`s rather than an enum because the kind
/// column is stored as text in Drift — an enum would need a two-way
/// mapping either way and would be overkill for 3 values.
library;

/// Matches [DailyBrief] payload.
const String kSynthesisKindDailyBrief = 'daily_brief';

/// Matches [WeeklyThemes] payload.
const String kSynthesisKindWeeklyThemes = 'weekly_themes';

/// Matches [MonthlyShifts] payload.
const String kSynthesisKindMonthlyShifts = 'monthly_shifts';
