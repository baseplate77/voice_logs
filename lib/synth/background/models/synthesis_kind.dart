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

/// Phase 8 — periodic sweep over the memory store to catch duplicate /
/// contradiction pairs the on-ingest consolidator missed.
const String kJobKindMemoryConsolidation = 'memory_consolidation';

/// Phase 8 — rebuild the always-on profile summary when the stale
/// flag is set. Runs daily; the profile also rebuilds lazily on the
/// next query so this is just "make it not block the user".
const String kJobKindProfileRefresh = 'profile_refresh';
