/// Single source of truth for phrases that flip the synthesizer from
/// single-shot RAG into multi-hop temporal retrieval. IMPLEMENTATION_PLAN
/// §7 deliberately picked a keyword classifier over an ML one: low
/// latency, trivial to debug, and it's enough because temporal queries
/// use a small set of English patterns.
///
/// Keywords are matched case-insensitively against the full query. Two
/// categories:
/// 1. Evolution phrases ("how has", "over time", "evolved", "changed",
///    "trend", "trajectory"): the user wants to see the story arc.
/// 2. Relative-time windows ("this week", "this month", "last week",
///    "last month", "recently"): user wants a time-bounded view.
///
/// Both route to the same multi-hop path — the retriever decides the
/// window internally.
const List<String> kTemporalKeywords = <String>[
  'how has',
  'how have',
  'over time',
  'over the last',
  'evolved',
  'changed',
  'changing',
  'trend',
  'trajectory',
  'progression',
  'history',
  'this week',
  'this month',
  'last week',
  'last month',
  'recently',
  'lately',
];

/// Returns true when [query] smells temporal. Empty / whitespace-only
/// queries return false so the callsite can short-circuit without
/// doing a full keyword scan.
bool isTemporalQuery(String query) {
  final trimmed = query.trim();
  if (trimmed.isEmpty) return false;
  final lower = trimmed.toLowerCase();
  for (final kw in kTemporalKeywords) {
    if (lower.contains(kw)) return true;
  }
  return false;
}
