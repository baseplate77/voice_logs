import 'search_filters.dart';

/// A cheap local interpretation of a human search question.
///
/// The app still uses local FTS/vector/entity retrieval. This class just
/// strips question scaffolding ("what did ... say"), separates temporal
/// phrases ("yesterday"), and keeps the terms worth using for exact matches
/// and UI highlights.
class NaturalLanguageSearchQuery {
  const NaturalLanguageSearchQuery({
    required this.rawQuery,
    required this.semanticQuery,
    required this.lexicalTerms,
    required this.highlightTerms,
    required this.queryTokens,
    this.dateRange,
    this.dateLabel,
  });

  final String rawQuery;
  final String semanticQuery;
  final List<String> lexicalTerms;
  final List<String> highlightTerms;
  final List<String> queryTokens;
  final DateRange? dateRange;
  final String? dateLabel;

  bool get hasLexicalTerms => lexicalTerms.isNotEmpty;
  bool get hasDateConstraint => dateRange != null;

  static NaturalLanguageSearchQuery parse(String query, {DateTime? now}) {
    final raw = query.trim();
    final reference = now ?? DateTime.now();
    final today = DateTime(reference.year, reference.month, reference.day);
    var searchable = raw.toLowerCase();
    DateRange? dateRange;
    String? dateLabel;

    void inferDate(String label, DateRange range, List<RegExp> patterns) {
      if (dateRange != null) return;
      var matched = false;
      for (final pattern in patterns) {
        if (pattern.hasMatch(searchable)) {
          searchable = searchable.replaceAll(pattern, ' ');
          matched = true;
        }
      }
      if (!matched) return;
      dateRange = range;
      dateLabel = label;
    }

    DateRange wholeDay(DateTime day) => DateRange(
      start: day,
      end: day
          .add(const Duration(days: 1))
          .subtract(const Duration(milliseconds: 1)),
    );

    inferDate('today', wholeDay(today), [RegExp(r'\btoday\b')]);
    inferDate('yesterday', wholeDay(today.subtract(const Duration(days: 1))), [
      RegExp(r'\byesterday\b'),
    ]);
    inferDate(
      'last 7 days',
      DateRange(start: today.subtract(const Duration(days: 7))),
      [RegExp(r'\b(last|past)\s+7\s+days\b'), RegExp(r'\blast\s+week\b')],
    );
    inferDate(
      'last 30 days',
      DateRange(start: today.subtract(const Duration(days: 30))),
      [RegExp(r'\b(last|past)\s+30\s+days\b'), RegExp(r'\blast\s+month\b')],
    );
    inferDate(
      'this week',
      DateRange(start: today.subtract(Duration(days: today.weekday - 1))),
      [RegExp(r'\bthis\s+week\b')],
    );

    final queryTokens = _tokens(raw);
    final lexicalTerms = <String>[];
    final seen = <String>{};
    for (final token in _tokens(searchable)) {
      final normalized = token.endsWith("'s")
          ? token.substring(0, token.length - 2)
          : token;
      if (normalized.length <= 1 || _stopWords.contains(normalized)) {
        continue;
      }
      if (seen.add(normalized)) lexicalTerms.add(normalized);
    }

    final semanticQuery = searchable.replaceAll(RegExp(r'\s+'), ' ').trim();
    return NaturalLanguageSearchQuery(
      rawQuery: raw,
      semanticQuery: semanticQuery.isEmpty ? raw : semanticQuery,
      lexicalTerms: lexicalTerms,
      highlightTerms: List.unmodifiable(lexicalTerms),
      queryTokens: queryTokens,
      dateRange: dateRange,
      dateLabel: dateLabel,
    );
  }

  bool containsEntityName(String displayName) {
    final nameTokens = _tokens(displayName);
    if (nameTokens.isEmpty || queryTokens.isEmpty) return false;
    if (nameTokens.length == 1) {
      return queryTokens.any((token) => _closeToken(token, nameTokens.single));
    }
    return nameTokens.every(
      (nameToken) => queryTokens.any((token) => _closeToken(token, nameToken)),
    );
  }

  NaturalLanguageSearchQuery withExtraHighlightTerms(Iterable<String> terms) {
    final seen = <String>{...highlightTerms};
    final merged = <String>[...highlightTerms];
    for (final token in terms.expand(_tokens)) {
      if (token.length <= 1 || !seen.add(token)) continue;
      merged.add(token);
    }
    return NaturalLanguageSearchQuery(
      rawQuery: rawQuery,
      semanticQuery: semanticQuery,
      lexicalTerms: lexicalTerms,
      highlightTerms: List.unmodifiable(merged),
      queryTokens: queryTokens,
      dateRange: dateRange,
      dateLabel: dateLabel,
    );
  }

  static List<String> _tokens(String value) {
    return RegExp(r"[a-z0-9]+(?:'[a-z0-9]+)?")
        .allMatches(value.toLowerCase())
        .map((m) => m.group(0)!)
        .toList(growable: false);
  }

  static bool _closeToken(String queryToken, String nameToken) {
    if (queryToken == nameToken) return true;
    if (queryToken.length < 3 || nameToken.length < 3) return false;
    if ((queryToken.length - nameToken.length).abs() > 1) return false;
    return _damerauLevenshteinDistance(queryToken, nameToken) <= 1;
  }

  static int _damerauLevenshteinDistance(String a, String b) {
    final rows = a.length + 1;
    final cols = b.length + 1;
    final dp = List.generate(rows, (_) => List<int>.filled(cols, 0));
    for (var i = 0; i < rows; i++) {
      dp[i][0] = i;
    }
    for (var j = 0; j < cols; j++) {
      dp[0][j] = j;
    }
    for (var i = 1; i < rows; i++) {
      for (var j = 1; j < cols; j++) {
        final cost = a[i - 1] == b[j - 1] ? 0 : 1;
        var best = dp[i - 1][j] + 1;
        best = _min(best, dp[i][j - 1] + 1);
        best = _min(best, dp[i - 1][j - 1] + cost);
        if (i > 1 && j > 1 && a[i - 1] == b[j - 2] && a[i - 2] == b[j - 1]) {
          best = _min(best, dp[i - 2][j - 2] + 1);
        }
        dp[i][j] = best;
      }
    }
    return dp[a.length][b.length];
  }

  static int _min(int a, int b) => a < b ? a : b;

  static final _stopWords = {
    'i',
    'me',
    'my',
    'we',
    'our',
    'you',
    'your',
    'he',
    'she',
    'it',
    'they',
    'them',
    'a',
    'an',
    'the',
    'is',
    'am',
    'are',
    'was',
    'were',
    'be',
    'been',
    'being',
    'have',
    'has',
    'had',
    'do',
    'does',
    'did',
    'will',
    'would',
    'could',
    'should',
    'can',
    'may',
    'might',
    'at',
    'in',
    'on',
    'to',
    'for',
    'of',
    'with',
    'by',
    'from',
    'about',
    'that',
    'this',
    'what',
    'which',
    'who',
    'whom',
    'when',
    'where',
    'why',
    'how',
    'and',
    'or',
    'but',
    'not',
    'no',
    'if',
    'so',
    'than',
    'as',
    'please',
    'show',
    'find',
    'search',
    'look',
    'tell',
    'told',
    'say',
    'said',
    'says',
    'saying',
    'mention',
    'mentioned',
    'talk',
    'talked',
    'discuss',
    'discussed',
    'get',
    'got',
    'give',
    'gave',
    'log',
    'logs',
    'entry',
    'entries',
    'journal',
    'voice',
    'note',
    'notes',
    'memory',
    'memories',
  };
}
