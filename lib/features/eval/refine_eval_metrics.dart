import 'refine_eval_case.dart';

/// Predicted vs expected entity comparison. Greedy 1-to-1 bipartite
/// match by normalized text; type accuracy is computed only over the
/// text-matched pairs so a model that hallucinates many entities is not
/// rewarded with cheap type hits.
class EntityMetrics {
  const EntityMetrics({
    required this.predictedCount,
    required this.expectedCount,
    required this.textMatched,
    required this.typeMatched,
  });

  final int predictedCount;
  final int expectedCount;
  final int textMatched;
  final int typeMatched;

  double get precision =>
      predictedCount == 0 ? 0 : textMatched / predictedCount;
  double get recall => expectedCount == 0 ? 1 : textMatched / expectedCount;
  double get f1 {
    final p = precision;
    final r = recall;
    if (p + r == 0) return 0;
    return 2 * p * r / (p + r);
  }

  double get typeAccuracy => textMatched == 0 ? 0 : typeMatched / textMatched;
}

/// Token-level overlap similarity for the cleaned-text field. We use a
/// multiset SQuAD-style F1 plus a length ratio so over-shortening (the
/// classic "the model summarized the transcript" failure) shows up
/// distinctly from under-editing.
class CleanedTextMetrics {
  const CleanedTextMetrics({
    required this.wordF1,
    required this.lengthRatio,
    required this.exactMatch,
    required this.predictedWordCount,
    required this.expectedWordCount,
  });

  final double wordF1;
  final double lengthRatio;
  final bool exactMatch;
  final int predictedWordCount;
  final int expectedWordCount;
}

/// Per-case eval bundle held in the screen state.
class RefineEvalCaseResult {
  const RefineEvalCaseResult({
    required this.caseId,
    required this.parseStatus,
    required this.predictedCleanedText,
    required this.predictedEntities,
    required this.entityMetrics,
    required this.cleanedTextMetrics,
    required this.elapsed,
    this.error,
  });

  final String caseId;
  final RefineParseStatus parseStatus;
  final String predictedCleanedText;
  final List<RefineEvalEntity> predictedEntities;
  final EntityMetrics entityMetrics;
  final CleanedTextMetrics cleanedTextMetrics;
  final Duration elapsed;
  final String? error;
}

enum RefineParseStatus { firstPass, retry, fallback, generationError }

EntityMetrics computeEntityMetrics({
  required List<RefineEvalEntity> expected,
  required List<RefineEvalEntity> predicted,
}) {
  final remaining = predicted.map((e) => _normEntityText(e.text)).toList();
  final remainingTypes = predicted.map((e) => e.type.toUpperCase()).toList();
  final used = List<bool>.filled(predicted.length, false);

  var textHits = 0;
  var typeHits = 0;
  for (final exp in expected) {
    final expText = _normEntityText(exp.text);
    final expType = exp.type.toUpperCase();
    for (var i = 0; i < remaining.length; i++) {
      if (used[i]) continue;
      if (remaining[i] == expText) {
        used[i] = true;
        textHits += 1;
        if (remainingTypes[i] == expType) typeHits += 1;
        break;
      }
    }
  }

  return EntityMetrics(
    predictedCount: predicted.length,
    expectedCount: expected.length,
    textMatched: textHits,
    typeMatched: typeHits,
  );
}

CleanedTextMetrics computeCleanedTextMetrics({
  required String expected,
  required String predicted,
}) {
  final expWords = _wordTokens(expected);
  final predWords = _wordTokens(predicted);

  final expCounts = <String, int>{};
  for (final w in expWords) {
    expCounts[w] = (expCounts[w] ?? 0) + 1;
  }
  var overlap = 0;
  for (final w in predWords) {
    final c = expCounts[w];
    if (c != null && c > 0) {
      overlap += 1;
      expCounts[w] = c - 1;
    }
  }

  final precision = predWords.isEmpty ? 0.0 : overlap / predWords.length;
  final recall = expWords.isEmpty ? 1.0 : overlap / expWords.length;
  final f1 = (precision + recall) == 0
      ? 0.0
      : 2 * precision * recall / (precision + recall);

  final lengthRatio = expWords.isEmpty
      ? (predWords.isEmpty ? 1.0 : double.infinity)
      : predWords.length / expWords.length;

  return CleanedTextMetrics(
    wordF1: f1,
    lengthRatio: lengthRatio,
    exactMatch: _normalizeForExact(expected) == _normalizeForExact(predicted),
    predictedWordCount: predWords.length,
    expectedWordCount: expWords.length,
  );
}

/// Aggregate roll-up across a list of per-case results. Used for the
/// summary card in the eval screen.
class RefineEvalAggregate {
  const RefineEvalAggregate({
    required this.cases,
    required this.firstPassParses,
    required this.retryParses,
    required this.fallbacks,
    required this.errors,
    required this.entityPrecision,
    required this.entityRecall,
    required this.entityF1,
    required this.typeAccuracy,
    required this.meanWordF1,
    required this.meanLengthRatio,
    required this.exactMatches,
  });

  final int cases;
  final int firstPassParses;
  final int retryParses;
  final int fallbacks;
  final int errors;

  /// Micro-averaged across all cases (sum of TP, FP, FN). Micro is more
  /// honest than macro when expected counts vary by case.
  final double entityPrecision;
  final double entityRecall;
  final double entityF1;
  final double typeAccuracy;

  final double meanWordF1;
  final double meanLengthRatio;
  final int exactMatches;
}

RefineEvalAggregate aggregate(List<RefineEvalCaseResult> results) {
  if (results.isEmpty) {
    return const RefineEvalAggregate(
      cases: 0,
      firstPassParses: 0,
      retryParses: 0,
      fallbacks: 0,
      errors: 0,
      entityPrecision: 0,
      entityRecall: 0,
      entityF1: 0,
      typeAccuracy: 0,
      meanWordF1: 0,
      meanLengthRatio: 0,
      exactMatches: 0,
    );
  }

  var firstPass = 0;
  var retry = 0;
  var fallback = 0;
  var errors = 0;
  var tpSum = 0;
  var predSum = 0;
  var expSum = 0;
  var typeMatchSum = 0;
  var f1Sum = 0.0;
  var ratioSum = 0.0;
  var ratioCount = 0;
  var exact = 0;

  for (final r in results) {
    switch (r.parseStatus) {
      case RefineParseStatus.firstPass:
        firstPass += 1;
      case RefineParseStatus.retry:
        retry += 1;
      case RefineParseStatus.fallback:
        fallback += 1;
      case RefineParseStatus.generationError:
        errors += 1;
    }
    tpSum += r.entityMetrics.textMatched;
    predSum += r.entityMetrics.predictedCount;
    expSum += r.entityMetrics.expectedCount;
    typeMatchSum += r.entityMetrics.typeMatched;
    f1Sum += r.cleanedTextMetrics.wordF1;
    if (r.cleanedTextMetrics.lengthRatio.isFinite) {
      ratioSum += r.cleanedTextMetrics.lengthRatio;
      ratioCount += 1;
    }
    if (r.cleanedTextMetrics.exactMatch) exact += 1;
  }

  final precision = predSum == 0 ? 0.0 : tpSum / predSum;
  final recall = expSum == 0 ? 1.0 : tpSum / expSum;
  final f1 = (precision + recall) == 0
      ? 0.0
      : 2 * precision * recall / (precision + recall);
  final typeAcc = tpSum == 0 ? 0.0 : typeMatchSum / tpSum;

  return RefineEvalAggregate(
    cases: results.length,
    firstPassParses: firstPass,
    retryParses: retry,
    fallbacks: fallback,
    errors: errors,
    entityPrecision: precision,
    entityRecall: recall,
    entityF1: f1,
    typeAccuracy: typeAcc,
    meanWordF1: f1Sum / results.length,
    meanLengthRatio: ratioCount == 0 ? 0 : ratioSum / ratioCount,
    exactMatches: exact,
  );
}

String _normEntityText(String s) =>
    s.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

List<String> _wordTokens(String text) {
  final lower = text.toLowerCase();
  return RegExp(
    r"[a-z0-9]+(?:'[a-z]+)?",
  ).allMatches(lower).map((m) => m.group(0)!).toList();
}

String _normalizeForExact(String s) => s.trim().replaceAll(RegExp(r'\s+'), ' ');
