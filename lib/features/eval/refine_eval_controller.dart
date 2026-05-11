import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/logger.dart';
import '../../core/result.dart';
import '../../core/worker/providers.dart';
import '../refine/llm_runner.dart';
import '../refine/prompt_templates.dart';
import '../refine/response_parser.dart';
import 'refine_eval_case.dart';
import 'refine_eval_metrics.dart';

/// UI-facing snapshot of an in-progress or completed eval run.
class RefineEvalState {
  const RefineEvalState({
    required this.cases,
    required this.results,
    required this.running,
    required this.cancelRequested,
    this.currentIndex,
    this.errorMessage,
  });

  const RefineEvalState.initial()
    : cases = const [],
      results = const [],
      running = false,
      cancelRequested = false,
      currentIndex = null,
      errorMessage = null;

  final List<RefineEvalCase> cases;
  final List<RefineEvalCaseResult> results;
  final bool running;
  final bool cancelRequested;
  final int? currentIndex;
  final String? errorMessage;

  RefineEvalState copyWith({
    List<RefineEvalCase>? cases,
    List<RefineEvalCaseResult>? results,
    bool? running,
    bool? cancelRequested,
    int? currentIndex,
    bool clearCurrent = false,
    String? errorMessage,
    bool clearError = false,
  }) {
    return RefineEvalState(
      cases: cases ?? this.cases,
      results: results ?? this.results,
      running: running ?? this.running,
      cancelRequested: cancelRequested ?? this.cancelRequested,
      currentIndex: clearCurrent ? null : (currentIndex ?? this.currentIndex),
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
    );
  }
}

/// Drives the refine pipeline over the bundled fixture, sequentially,
/// reusing the live Gemma 3 runner. Mirrors `LlmRefiner.handle` for
/// cleanup/entity parse/retry/fallback so the eval reflects production.
class RefineEvalController extends StateNotifier<RefineEvalState> {
  RefineEvalController(this._runner) : super(const RefineEvalState.initial());

  final LlmRunner _runner;
  final _log = Logger('refine_eval');

  Future<void> start() async {
    if (state.running) return;
    state = const RefineEvalState.initial().copyWith(running: true);

    final List<RefineEvalCase> cases;
    try {
      cases = await loadRefineEvalCases();
    } on Object catch (e, st) {
      _log.w('Eval fixture load failed', error: e, stack: st);
      state = state.copyWith(
        running: false,
        errorMessage: 'Failed to load fixture: $e',
      );
      return;
    }

    state = state.copyWith(cases: cases);

    final loaded = await _runner.load();
    switch (loaded) {
      case Ok():
        break;
      case Err(:final error):
        state = state.copyWith(
          running: false,
          errorMessage: 'Model load failed: ${error.message}',
        );
        return;
    }

    final accumulated = <RefineEvalCaseResult>[];
    for (var i = 0; i < cases.length; i++) {
      if (state.cancelRequested) break;
      state = state.copyWith(currentIndex: i);

      final result = await _runOne(cases[i]);
      accumulated.add(result);
      state = state.copyWith(results: List.unmodifiable(accumulated));
    }

    state = state.copyWith(
      running: false,
      cancelRequested: false,
      clearCurrent: true,
    );
  }

  void cancel() {
    if (!state.running) return;
    state = state.copyWith(cancelRequested: true);
  }

  Future<RefineEvalCaseResult> _runOne(RefineEvalCase c) async {
    final stopwatch = Stopwatch()..start();
    var status = RefineParseStatus.firstPass;

    final firstCleanup = await _runner.generate(
      cleanupTranscriptPrompt(c.rawTranscript),
      temperature: kRecordLogTemperature,
    );

    String? rawCleanup;
    switch (firstCleanup) {
      case Ok(:final value):
        rawCleanup = value;
      case Err(:final error):
        stopwatch.stop();
        return _emptyResult(
          c,
          RefineParseStatus.generationError,
          elapsed: stopwatch.elapsed,
          error: error.message,
        );
    }

    var cleaned = parseCleanedTranscript(rawCleanup);
    if (cleaned == null) {
      final retryCleanup = await _runner.generate(
        cleanupTranscriptRetryPrompt(c.rawTranscript, rawCleanup),
        temperature: kRecordLogTemperature,
      );
      switch (retryCleanup) {
        case Ok(:final value):
          cleaned = parseCleanedTranscript(value);
          status = cleaned == null
              ? RefineParseStatus.fallback
              : RefineParseStatus.retry;
        case Err(:final error):
          stopwatch.stop();
          return _emptyResult(
            c,
            RefineParseStatus.generationError,
            elapsed: stopwatch.elapsed,
            error: error.message,
          );
      }
    }

    if (cleaned == null) {
      stopwatch.stop();
      return _emptyResult(c, status, elapsed: stopwatch.elapsed);
    }

    final firstEntities = await _runner.generate(
      entityExtractionPrompt(cleaned),
      temperature: kRecordLogTemperature,
    );
    String? rawEntities;
    switch (firstEntities) {
      case Ok(:final value):
        rawEntities = value;
      case Err(:final error):
        stopwatch.stop();
        return _emptyResult(
          c,
          RefineParseStatus.generationError,
          elapsed: stopwatch.elapsed,
          error: error.message,
        );
    }

    var mentions = parseEntityMentions(rawEntities, cleanedText: cleaned);
    if (mentions == null) {
      final retryEntities = await _runner.generate(
        entityExtractionRetryPrompt(cleaned, rawEntities),
        temperature: kRecordLogTemperature,
      );
      switch (retryEntities) {
        case Ok(:final value):
          mentions = parseEntityMentions(value, cleanedText: cleaned);
          status = status == RefineParseStatus.firstPass
              ? (mentions == null
                    ? RefineParseStatus.fallback
                    : RefineParseStatus.retry)
              : status;
        case Err(:final error):
          stopwatch.stop();
          return _emptyResult(
            c,
            RefineParseStatus.generationError,
            elapsed: stopwatch.elapsed,
            error: error.message,
          );
      }
    }

    stopwatch.stop();

    final entities = (mentions ?? const <({String text, String type})>[])
        .map((m) => RefineEvalEntity(text: m.text, type: m.type))
        .toList();

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
      elapsed: stopwatch.elapsed,
    );
  }

  RefineEvalCaseResult _emptyResult(
    RefineEvalCase c,
    RefineParseStatus status, {
    required Duration elapsed,
    String? error,
  }) {
    return RefineEvalCaseResult(
      caseId: c.id,
      parseStatus: status,
      predictedCleanedText: c.rawTranscript,
      predictedEntities: const [],
      entityMetrics: computeEntityMetrics(
        expected: c.expectedEntities,
        predicted: const [],
      ),
      cleanedTextMetrics: computeCleanedTextMetrics(
        expected: c.expectedCleanedText,
        predicted: c.rawTranscript,
      ),
      elapsed: elapsed,
      error: error,
    );
  }
}

final refineEvalControllerProvider =
    StateNotifierProvider.autoDispose<RefineEvalController, RefineEvalState>((
      ref,
    ) {
      ref.keepAlive();
      final runner = ref.watch(llmRunnerProvider);
      return RefineEvalController(runner);
    });
