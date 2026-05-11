/// Deterministic importance scoring for voice-log segments and memory
/// candidates. Scores range [0, 1] and influence memory promotion and
/// search ranking.
library;

/// Computes an importance score for a text segment based on keyword
/// heuristics. [entityNames] and [repeatedTopics] provide corpus-level
/// context when available.
double computeImportance(
  String text, {
  Set<String> entityNames = const {},
  Set<String> repeatedTopics = const {},
}) {
  double score = 0.3;
  final lower = text.toLowerCase();

  if (_matchesAny(lower, _rememberKeywords)) score += 0.25;
  if (_matchesAny(lower, _decisionKeywords)) score += 0.25;
  if (_matchesAny(lower, _taskKeywords)) score += 0.2;
  if (_matchesAny(lower, _goalKeywords)) score += 0.15;
  if (_matchesAny(lower, _meetingKeywords)) score += 0.15;
  if (_hasFutureTimeReference(lower)) score += 0.15;
  if (_matchesRepeatedTopic(lower, repeatedTopics)) score += 0.15;
  if (_hasStrongEmotion(lower)) score += 0.1;
  if (_mentionsEntity(lower, entityNames)) score += 0.1;

  return score.clamp(0.0, 1.0);
}

const _rememberKeywords = [
  r'\bremember\b',
  r'\bimportant\b',
  r'\bdon.t forget\b',
  r'\bnote to self\b',
];

const _decisionKeywords = [
  r'\bi decided\b',
  r'\bdecision\b',
  r'\bdecided\b',
  r'\bgoing to\b',
  r'\bcommitting to\b',
];

const _taskKeywords = [
  r'\btodo\b',
  r'\btask\b',
  r'\bi need to\b',
  r'\bi have to\b',
  r'\bi should\b',
  r'\bi must\b',
  r'\baction item\b',
];

const _goalKeywords = [
  r'\bgoal\b',
  r'\bidea\b',
  r'\bplan\b',
  r'\bproject\b',
  r'\bambition\b',
];

const _meetingKeywords = [
  r'\bdeadline\b',
  r'\bmeeting\b',
  r'\bfollow up\b',
  r'\bappointment\b',
  r'\bschedule\b',
];

const _emotionWords = [
  r'\bfrustrat',
  r'\bexcit',
  r'\bangr',
  r'\bhappy\b',
  r'\bworried\b',
  r'\banxious\b',
  r'\bstress',
  r'\bproud\b',
  r'\bafraid\b',
  r'\blove\b',
  r'\bhate\b',
  r'\boverwhelm',
];

final _futureTimePattern = RegExp(
  r'\b(tomorrow|next week|next month|next year|'
  r'monday|tuesday|wednesday|thursday|friday|saturday|sunday|'
  r'january|february|march|april|may|june|july|august|'
  r'september|october|november|december|'
  r'by \w+day|due date|deadline|in \d+ days?|in \d+ weeks?)\b',
  caseSensitive: false,
);

bool _matchesAny(String lower, List<String> patterns) {
  for (final pattern in patterns) {
    if (RegExp(pattern, caseSensitive: false).hasMatch(lower)) return true;
  }
  return false;
}

bool _hasFutureTimeReference(String lower) =>
    _futureTimePattern.hasMatch(lower);

bool _hasStrongEmotion(String lower) => _matchesAny(lower, _emotionWords);

bool _matchesRepeatedTopic(String lower, Set<String> repeatedTopics) {
  for (final topic in repeatedTopics) {
    if (lower.contains(topic.toLowerCase())) return true;
  }
  return false;
}

bool _mentionsEntity(String lower, Set<String> entityNames) {
  for (final name in entityNames) {
    if (lower.contains(name.toLowerCase())) return true;
  }
  return false;
}
