// Run a small Gemma 3 1B two-stage refine eval on iOS simulator:
//   flutter test integration_test/gemma_refine_eval.dart \
//     -d <ios-simulator-id> --dart-define=REFINE_EVAL_LIMIT=3
//
// Run another local Gemma LiteRT-LM bundle by overriding the model defines:
//   flutter test integration_test/gemma_refine_eval.dart -d <device-id> \
//     --dart-define=REFINE_EVAL_LIMIT=3 \
//     --dart-define=GEMMA_MODEL_LABEL='Gemma 3 270M IT Q8 LiteRT-LM' \
//     --dart-define=GEMMA_ASSET_PATH=models/gemma/gemma3-270m-it-q8.litertlm \
//     --dart-define=GEMMA_MAX_TOKENS=1024
//
// Run the full 50-case eval:
//   flutter test integration_test/gemma_refine_eval.dart \
//     -d <device-id> --dart-define=REFINE_EVAL_LIMIT=50

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:voxsynth/core/native_paths.dart';
import 'package:voxsynth/features/eval/refine_eval_case.dart';
import 'package:voxsynth/features/eval/refine_eval_metrics.dart';
import 'package:voxsynth/features/refine/prompt_templates.dart';
import 'package:voxsynth/features/refine/response_parser.dart';

const _limit = int.fromEnvironment('REFINE_EVAL_LIMIT', defaultValue: 3);
const _maxTokens = int.fromEnvironment('GEMMA_MAX_TOKENS', defaultValue: 1024);
const _modelLabel = String.fromEnvironment(
  'GEMMA_MODEL_LABEL',
  defaultValue: 'Gemma 3 1B IT Q4 LiteRT-LM',
);
const _gemmaAssetPath = String.fromEnvironment(
  'GEMMA_ASSET_PATH',
  defaultValue:
      'models/gemma/Gemma3-1B-IT_multi-prefill-seq_q4_ekv4096.litertlm',
);
const _gemmaFileType = String.fromEnvironment(
  'GEMMA_FILE_TYPE',
  defaultValue: 'litertlm',
);
const _runtimeChannel = MethodChannel('com.nj.voxsynth/runtime');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('$_modelLabel refine eval', (tester) async {
    await FlutterGemma.initialize();

    final cases = (await loadRefineEvalCases()).take(_limit).toList();
    expect(cases, isNotEmpty);

    final runner = _GemmaEvalRunner(
      assetPath: _gemmaAssetPath,
      fileType: _parseFileType(_gemmaFileType),
      maxTokens: _maxTokens,
    );
    await runner.load();

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
        'gemma_refine_eval_${DateTime.now().millisecondsSinceEpoch}.json',
      ),
    );
    await reportFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(report),
      flush: true,
    );

    _printSummary(agg, reportFile.path);

    // Eval/benchmark only: fail only if Gemma cannot produce parseable output
    // for any case.
    expect(agg.firstPassParses + agg.retryParses, greaterThan(0));
  }, timeout: const Timeout(Duration(minutes: 60)));
}

class _GemmaEvalRunner {
  _GemmaEvalRunner({
    required this.assetPath,
    required this.fileType,
    required this.maxTokens,
  });

  final String assetPath;
  final ModelFileType fileType;
  final int maxTokens;
  InferenceModel? _model;

  Future<void> load() async {
    if (_model != null) return;
    final installWatch = Stopwatch()..start();
    // ignore: avoid_print
    print('Installing/activating $_modelLabel asset $assetPath …');
    final installation = await FlutterGemma.installModel(
      modelType: ModelType.gemmaIt,
      fileType: fileType,
    ).fromAsset(assetPath).install();
    // ignore: avoid_print
    print(
      'Gemma active model: ${installation.modelId} '
      'install_ms=${installWatch.elapsedMilliseconds}',
    );

    final isSimulator = await _isIosSimulator();
    final backend = isSimulator ? PreferredBackend.cpu : PreferredBackend.gpu;
    // ignore: avoid_print
    print('Loading Gemma backend=$backend maxTokens=$maxTokens …');
    final loadWatch = Stopwatch()..start();
    try {
      _model = await FlutterGemma.getActiveModel(
        maxTokens: maxTokens,
        preferredBackend: backend,
      );
      // ignore: avoid_print
      print('Gemma loaded in ${loadWatch.elapsedMilliseconds}ms');
    } on Object catch (e) {
      if (backend == PreferredBackend.gpu) {
        // ignore: avoid_print
        print('Gemma GPU load failed, retrying CPU: $e');
        _model = await FlutterGemma.getActiveModel(
          maxTokens: maxTokens,
          preferredBackend: PreferredBackend.cpu,
        );
        // ignore: avoid_print
        print('Gemma CPU loaded in ${loadWatch.elapsedMilliseconds}ms');
      } else {
        rethrow;
      }
    }
  }

  Future<String> generate(String prompt, {required double temperature}) async {
    await load();
    final model = _model;
    if (model == null) throw StateError('Gemma model not loaded');

    InferenceModelSession? session;
    try {
      session = await model.createSession(temperature: temperature);
      await session.addQueryChunk(Message.text(text: prompt, isUser: true));
      final out = StringBuffer();
      await for (final chunk in session.getResponseAsync()) {
        out.write(chunk);
      }
      return out.toString();
    } finally {
      await session?.close();
    }
  }

  Future<void> dispose() async {
    final model = _model;
    _model = null;
    await model?.close();
  }
}

Future<bool> _isIosSimulator() async {
  if (!Platform.isIOS) return false;
  try {
    return await _runtimeChannel.invokeMethod<bool>('isIosSimulator') ?? false;
  } on Object {
    return Platform.environment.containsKey('SIMULATOR_DEVICE_NAME');
  }
}

Future<RefineEvalCaseResult> _runOne(
  _GemmaEvalRunner runner,
  RefineEvalCase c,
) async {
  final stopwatch = Stopwatch()..start();
  try {
    final firstCleanup = await runner.generate(
      cleanupTranscriptPrompt(c.rawTranscript),
      temperature: kRecordLogTemperature,
    );

    var cleaned = parseCleanedTranscript(firstCleanup);
    var status = RefineParseStatus.firstPass;
    if (cleaned == null) {
      final retryCleanup = await runner.generate(
        cleanupTranscriptRetryPrompt(c.rawTranscript, firstCleanup),
        temperature: kRecordLogTemperature,
      );
      cleaned = parseCleanedTranscript(retryCleanup);
      status = cleaned == null
          ? RefineParseStatus.fallback
          : RefineParseStatus.retry;
    }

    if (cleaned == null) {
      stopwatch.stop();
      return _result(
        c,
        status: status,
        cleaned: c.rawTranscript,
        entities: const [],
        elapsed: stopwatch.elapsed,
      );
    }

    final firstEntities = await runner.generate(
      entityExtractionPrompt(cleaned),
      temperature: kRecordLogTemperature,
    );
    var mentions = parseEntityMentions(firstEntities, cleanedText: cleaned);
    if (mentions == null) {
      final retryEntities = await runner.generate(
        entityExtractionRetryPrompt(cleaned, firstEntities),
        temperature: kRecordLogTemperature,
      );
      mentions = parseEntityMentions(retryEntities, cleanedText: cleaned);
      if (status == RefineParseStatus.firstPass) {
        status = mentions == null
            ? RefineParseStatus.fallback
            : RefineParseStatus.retry;
      }
    }

    stopwatch.stop();
    final entities = (mentions ?? const <({String text, String type})>[])
        .map((m) => RefineEvalEntity(text: m.text, type: m.type))
        .toList();

    return _result(
      c,
      status: status,
      cleaned: cleaned,
      entities: entities,
      elapsed: stopwatch.elapsed,
    );
  } on Object catch (e) {
    stopwatch.stop();
    return _result(
      c,
      status: RefineParseStatus.generationError,
      cleaned: c.rawTranscript,
      entities: const [],
      elapsed: stopwatch.elapsed,
      error: e.toString(),
    );
  }
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
    'model': _modelLabel,
    'asset_path': _gemmaAssetPath,
    'file_type': _gemmaFileType,
    'limit': _limit,
    'max_tokens': _maxTokens,
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
  print('\n=== ${_modelLabel.toUpperCase()} REFINE EVAL SUMMARY ===');
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

ModelFileType _parseFileType(String value) {
  switch (value) {
    case 'task':
      return ModelFileType.task;
    case 'binary':
      return ModelFileType.binary;
    case 'litertlm':
      return ModelFileType.litertlm;
  }
  throw ArgumentError.value(value, 'GEMMA_FILE_TYPE', 'task, binary, litertlm');
}

String _pct(double value) => '${(value * 100).toStringAsFixed(1)}%';
