// Run a small smoke eval on macOS:
//   flutter test integration_test/smollm_refine_eval.dart -d macos \
//     --dart-define=REFINE_EVAL_LIMIT=3
//
// Run the full 50-case eval:
//   flutter test integration_test/smollm_refine_eval.dart -d macos \
//     --dart-define=REFINE_EVAL_LIMIT=50

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:voxsynth/core/native_paths.dart';
import 'package:voxsynth/core/result.dart';
import 'package:voxsynth/features/eval/refine_eval_case.dart';
import 'package:voxsynth/features/eval/refine_eval_metrics.dart';
import 'package:voxsynth/features/refine/prompt_templates.dart';
import 'package:voxsynth/features/refine/response_parser.dart';
import 'package:voxsynth/features/refine/smollm/smollm_runner.dart';

const _limit = int.fromEnvironment('REFINE_EVAL_LIMIT', defaultValue: 3);
const _maxNewTokens = int.fromEnvironment(
  'REFINE_EVAL_MAX_NEW_TOKENS',
  defaultValue: 512,
);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('SmolLM2 refine eval', (tester) async {
    final cases = (await loadRefineEvalCases()).take(_limit).toList();
    expect(cases, isNotEmpty);

    final runner = SmolLmRunner(
      maxNewTokens: _maxNewTokens,
      idleTtl: Duration.zero,
    );

    final loaded = await runner.load();
    switch (loaded) {
      case Ok():
        break;
      case Err(:final error):
        fail('SmolLM2 load failed: ${error.message}');
    }

    final results = <RefineEvalCaseResult>[];
    try {
      for (var i = 0; i < cases.length; i++) {
        final result = await _runOne(runner, cases[i]);
        results.add(result);
        _printCase(i + 1, cases.length, result);
      }
    } finally {
      await runner.dispose();
    }

    final agg = aggregate(results);
    final report = _reportJson(agg, results);
    final docsPath = await const NativePaths().applicationDocumentsPath();
    final reportFile = File(
      p.join(
        docsPath,
        'smollm_refine_eval_${DateTime.now().millisecondsSinceEpoch}.json',
      ),
    );
    await reportFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(report),
      flush: true,
    );

    _printSummary(agg, reportFile.path);

    // This is an eval/benchmark, not a hard quality gate. It should only fail
    // when the model cannot generate parseable output for any case.
    expect(agg.firstPassParses + agg.retryParses, greaterThan(0));
  }, timeout: const Timeout(Duration(minutes: 30)));
}

Future<RefineEvalCaseResult> _runOne(
  SmolLmRunner runner,
  RefineEvalCase c,
) async {
  final stopwatch = Stopwatch()..start();
  final first = await runner.generate(
    recordLogPrompt(c.rawTranscript),
    temperature: kRecordLogTemperature,
  );

  String? firstRaw;
  String? errorMessage;
  switch (first) {
    case Ok(:final value):
      firstRaw = value;
    case Err(:final error):
      errorMessage = error.message;
  }

  if (errorMessage != null) {
    stopwatch.stop();
    return _result(
      c,
      status: RefineParseStatus.generationError,
      cleaned: c.rawTranscript,
      entities: const [],
      elapsed: stopwatch.elapsed,
      error: errorMessage,
    );
  }

  var parsed = parseRecordLog(firstRaw!);
  var status = RefineParseStatus.firstPass;
  if (parsed == null) {
    final retry = await runner.generate(
      recordLogRetryPrompt(c.rawTranscript, firstRaw),
      temperature: kRecordLogTemperature,
    );
    switch (retry) {
      case Ok(:final value):
        parsed = parseRecordLog(value);
        status = parsed == null
            ? RefineParseStatus.fallback
            : RefineParseStatus.retry;
      case Err(:final error):
        stopwatch.stop();
        return _result(
          c,
          status: RefineParseStatus.generationError,
          cleaned: c.rawTranscript,
          entities: const [],
          elapsed: stopwatch.elapsed,
          error: error.message,
        );
    }
  }

  stopwatch.stop();
  final cleaned = parsed?.cleanedText ?? c.rawTranscript;
  final entities = parsed == null
      ? const <RefineEvalEntity>[]
      : parsed.mentions
            .map((m) => RefineEvalEntity(text: m.text, type: m.type))
            .toList();

  return _result(
    c,
    status: status,
    cleaned: cleaned,
    entities: entities,
    elapsed: stopwatch.elapsed,
  );
}

RefineEvalCaseResult _result(
  RefineEvalCase c, {
  required RefineParseStatus status,
  required String cleaned,
  required List<RefineEvalEntity> entities,
  required Duration elapsed,
  String? error,
}) {
  return RefineEvalCaseResult(
    caseId: c.id,
    parseStatus: status,
    predictedCleanedText: cleaned,
    predictedEntities: entities,
    entityMetrics: computeEntityMetrics(
      expected: c.expectedEntities,
      predicted: entities,
    ),
    cleanedTextMetrics: computeCleanedTextMetrics(
      expected: c.expectedCleanedText,
      predicted: cleaned,
    ),
    elapsed: elapsed,
    error: error,
  );
}

Map<String, Object?> _reportJson(
  RefineEvalAggregate agg,
  List<RefineEvalCaseResult> results,
) {
  return {
    'model': 'SmolLM2-360M-Instruct INT8 ONNX',
    'limit': _limit,
    'max_new_tokens': _maxNewTokens,
    'summary': {
      'cases': agg.cases,
      'first_pass': agg.firstPassParses,
      'retry': agg.retryParses,
      'fallback': agg.fallbacks,
      'errors': agg.errors,
      'entity_precision': agg.entityPrecision,
      'entity_recall': agg.entityRecall,
      'entity_f1': agg.entityF1,
      'entity_type_accuracy': agg.typeAccuracy,
      'cleaned_word_f1_mean': agg.meanWordF1,
      'cleaned_length_ratio_mean': agg.meanLengthRatio,
      'cleaned_exact_matches': agg.exactMatches,
    },
    'cases': [
      for (final r in results)
        {
          'id': r.caseId,
          'parse_status': r.parseStatus.name,
          'elapsed_ms': r.elapsed.inMilliseconds,
          'entity_precision': r.entityMetrics.precision,
          'entity_recall': r.entityMetrics.recall,
          'entity_f1': r.entityMetrics.f1,
          'entity_type_accuracy': r.entityMetrics.typeAccuracy,
          'cleaned_word_f1': r.cleanedTextMetrics.wordF1,
          'cleaned_length_ratio': r.cleanedTextMetrics.lengthRatio,
          'predicted_cleaned': r.predictedCleanedText,
          'predicted_entities': [
            for (final e in r.predictedEntities)
              {'text': e.text, 'type': e.type},
          ],
          if (r.error != null) 'error': r.error,
        },
    ],
  };
}

void _printCase(int index, int total, RefineEvalCaseResult r) {
  // ignore: avoid_print
  print(
    '[$index/$total] ${r.caseId} ${r.parseStatus.name} '
    '${r.elapsed.inMilliseconds}ms '
    'entity_f1=${_pct(r.entityMetrics.f1)} '
    'text_f1=${_pct(r.cleanedTextMetrics.wordF1)}',
  );
  // ignore: avoid_print
  print('  cleaned: ${r.predictedCleanedText}');
  // ignore: avoid_print
  print(
    '  entities: ${r.predictedEntities.map((e) => '${e.text}/${e.type}').join(', ')}',
  );
  if (r.error != null) {
    // ignore: avoid_print
    print('  error: ${r.error}');
  }
}

void _printSummary(RefineEvalAggregate agg, String reportPath) {
  // ignore: avoid_print
  print('\n=== SMOLLM2 REFINE EVAL SUMMARY ===');
  // ignore: avoid_print
  print(
    'cases=${agg.cases} first=${agg.firstPassParses} retry=${agg.retryParses} '
    'fallback=${agg.fallbacks} errors=${agg.errors}',
  );
  // ignore: avoid_print
  print(
    'entity P/R/F1=${_pct(agg.entityPrecision)} / '
    '${_pct(agg.entityRecall)} / ${_pct(agg.entityF1)}',
  );
  // ignore: avoid_print
  print('entity type accuracy=${_pct(agg.typeAccuracy)}');
  // ignore: avoid_print
  print('cleaned text mean word F1=${_pct(agg.meanWordF1)}');
  // ignore: avoid_print
  print(
    'cleaned text mean length ratio=${agg.meanLengthRatio.toStringAsFixed(2)}',
  );
  // ignore: avoid_print
  print('report: $reportPath');
}

String _pct(double value) => '${(value * 100).toStringAsFixed(1)}%';
