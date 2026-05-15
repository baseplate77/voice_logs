import '../search/search_filters.dart';

/// Build a retrieval-friendly query from a natural-language Ask question.
///
/// The original question is still sent to Gemma. This version removes temporal
/// phrases and common wrapper wording so keyword/FTS retrieval does not require
/// logs to literally contain words such as "last week" or "what did I say".
String buildAskRetrievalQuery(String question) {
  var q = question.toLowerCase();
  q = q.replaceAll(RegExp(r'[?!.]+'), ' ');
  q = q.replaceAll(
    RegExp(
      r'\b(today|yesterday|this week|last week|past week|last seven days|last 7 days|this month|last month)\b',
      caseSensitive: false,
    ),
    ' ',
  );
  q = q.replaceAll(
    RegExp(
      r'\b(what did i say about|what did we say about|what did i mention about|what did we mention about|tell me about|summarize|summary of|recap|show me|find|search for)\b',
      caseSensitive: false,
    ),
    ' ',
  );
  q = q.replaceAll(
    RegExp(r'\b(my|our|the|a|an|did|i|we|say|said|mention|mentioned|about)\b'),
    ' ',
  );
  q = q.replaceAll(RegExp(r'\s+'), ' ').trim();
  return q.isEmpty ? question.trim() : q;
}

/// Infer a coarse date filter from common Ask phrases.
///
/// Supports phrases users naturally ask in journal search, e.g. "last week" in
/// "What did I say about Atlas last week?". Returns an empty filter when no
/// supported temporal phrase appears.
SearchFilters inferAskSearchFilters(String question, {DateTime? now}) {
  final q = question.toLowerCase();
  final anchor = now ?? DateTime.now();

  DateRange? range;
  if (RegExp(r'\btoday\b').hasMatch(q)) {
    range = DateRange(start: _startOfDay(anchor), end: _endOfDay(anchor));
  } else if (RegExp(r'\byesterday\b').hasMatch(q)) {
    final day = anchor.subtract(const Duration(days: 1));
    range = DateRange(start: _startOfDay(day), end: _endOfDay(day));
  } else if (RegExp(r'\bthis week\b').hasMatch(q)) {
    range = DateRange(start: _startOfWeek(anchor), end: anchor);
  } else if (RegExp(r'\blast week\b').hasMatch(q)) {
    final thisWeek = _startOfWeek(anchor);
    final lastWeekStart = thisWeek.subtract(const Duration(days: 7));
    range = DateRange(
      start: lastWeekStart,
      end: thisWeek.subtract(const Duration(milliseconds: 1)),
    );
  } else if (RegExp(
    r'\b(past week|last seven days|last 7 days)\b',
  ).hasMatch(q)) {
    range = DateRange(
      start: anchor.subtract(const Duration(days: 7)),
      end: anchor,
    );
  } else if (RegExp(r'\bthis month\b').hasMatch(q)) {
    range = DateRange(start: DateTime(anchor.year, anchor.month), end: anchor);
  } else if (RegExp(r'\blast month\b').hasMatch(q)) {
    final thisMonth = DateTime(anchor.year, anchor.month);
    final lastMonthStart = DateTime(anchor.year, anchor.month - 1);
    range = DateRange(
      start: lastMonthStart,
      end: thisMonth.subtract(const Duration(milliseconds: 1)),
    );
  }

  return range == null
      ? const SearchFilters()
      : SearchFilters(dateRange: range);
}

DateTime _startOfDay(DateTime dt) => DateTime(dt.year, dt.month, dt.day);

DateTime _endOfDay(DateTime dt) => DateTime(
  dt.year,
  dt.month,
  dt.day + 1,
).subtract(const Duration(milliseconds: 1));

DateTime _startOfWeek(DateTime dt) {
  final day = _startOfDay(dt);
  return day.subtract(Duration(days: day.weekday - DateTime.monday));
}
