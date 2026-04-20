import 'package:freezed_annotation/freezed_annotation.dart';

part 'daily_brief.freezed.dart';
part 'daily_brief.g.dart';

/// Output schema for [DailyBriefJob] — one document summarising a
/// single day's chunks. Round-trips through [SynthesisRecord.payloadJson]
/// via `toJson` / `fromJson` generated here.
@freezed
class DailyBrief with _$DailyBrief {
  const factory DailyBrief({
    /// The day this brief covers, as `YYYY-MM-DD` in the user's local
    /// timezone. String rather than DateTime because the payload is
    /// JSON — and the job reads the day off `Synthesis.periodStart`
    /// anyway, this is just a human-readable label.
    required String date,

    /// 1-paragraph summary of the day. Never empty (jobs fall back to
    /// "No activity on this day." on a quiet day).
    required String summary,

    /// Action items extracted from the day. Empty when none detected.
    required List<DailyActionItem> actionItems,

    /// 3–5 key moments. May have fewer if the day was quiet.
    required List<DailyKeyMoment> keyMoments,
  }) = _DailyBrief;

  factory DailyBrief.fromJson(Map<String, Object?> json) =>
      _$DailyBriefFromJson(json);
}

/// One extracted action item with back-references to supporting
/// chunks so the UI can jump the user to the source.
@freezed
class DailyActionItem with _$DailyActionItem {
  const factory DailyActionItem({
    required String text,
    required List<int> sourceChunkIds,
  }) = _DailyActionItem;

  factory DailyActionItem.fromJson(Map<String, Object?> json) =>
      _$DailyActionItemFromJson(json);
}

/// A notable moment from the day — a decision, a realisation, a
/// question that opened.
@freezed
class DailyKeyMoment with _$DailyKeyMoment {
  const factory DailyKeyMoment({
    required String description,
    required List<int> sourceChunkIds,
  }) = _DailyKeyMoment;

  factory DailyKeyMoment.fromJson(Map<String, Object?> json) =>
      _$DailyKeyMomentFromJson(json);
}
