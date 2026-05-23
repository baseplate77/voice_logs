import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import 'refine_eval_case.dart';
import 'refine_eval_controller.dart';
import 'refine_eval_metrics.dart';

/// Debug screen that runs the bundled 50-case refine fixture through the
/// live SmolLM2 runner and reports entity P/R/F1 + cleaned-text word F1.
class RefineEvalScreen extends ConsumerWidget {
  const RefineEvalScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(refineEvalControllerProvider);
    final controller = ref.read(refineEvalControllerProvider.notifier);
    final agg = aggregate(state.results);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Refine eval'),
        actions: [
          IconButton(
            tooltip: 'Copy report JSON',
            icon: const Icon(Icons.copy_outlined),
            onPressed: state.results.isEmpty
                ? null
                : () => _copyReport(context, state, agg),
          ),
        ],
      ),
      body: Column(
        children: [
          _ControlBar(state: state, controller: controller),
          if (state.errorMessage != null)
            Padding(
              padding: EdgeInsets.all(12.r),
              child: Text(
                state.errorMessage!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          if (state.results.isNotEmpty) _SummaryCard(agg: agg),
          Divider(height: 1.h),
          Expanded(child: _CaseList(state: state)),
        ],
      ),
    );
  }

  Future<void> _copyReport(
    BuildContext context,
    RefineEvalState state,
    RefineEvalAggregate agg,
  ) async {
    final report = {
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
        for (final r in state.results)
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
            'cleaned_exact_match': r.cleanedTextMetrics.exactMatch,
            'predicted_cleaned': r.predictedCleanedText,
            'predicted_entities': [
              for (final e in r.predictedEntities)
                {'text': e.text, 'type': e.type},
            ],
            if (r.error != null) 'error': r.error,
          },
      ],
    };
    final encoded = const JsonEncoder.withIndent('  ').convert(report);
    await Clipboard.setData(ClipboardData(text: encoded));
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Report copied to clipboard')));
  }
}

class _ControlBar extends StatelessWidget {
  const _ControlBar({required this.state, required this.controller});

  final RefineEvalState state;
  final RefineEvalController controller;

  @override
  Widget build(BuildContext context) {
    final running = state.running;
    final progress = state.cases.isEmpty
        ? null
        : (state.results.length / state.cases.length).clamp(0.0, 1.0);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  icon: Icon(running ? Icons.stop : Icons.play_arrow),
                  label: Text(running ? 'Cancel' : 'Run 50-case eval'),
                  onPressed: running ? controller.cancel : controller.start,
                ),
              ),
            ],
          ),
          SizedBox(height: 8.h),
          if (running)
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  state.currentIndex == null
                      ? 'Loading model…'
                      : 'Case ${state.currentIndex! + 1} / ${state.cases.length}'
                            ' — ${state.cases[state.currentIndex!].id}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                SizedBox(height: 4.h),
                LinearProgressIndicator(value: progress),
              ],
            )
          else if (state.results.isNotEmpty)
            Text(
              'Done — ${state.results.length} / ${state.cases.length} cases',
              style: Theme.of(context).textTheme.bodySmall,
            )
          else
            Text(
              'LLM inference is serial. Avoid recording while eval runs.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
        ],
      ),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.agg});

  final RefineEvalAggregate agg;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Padding(
        padding: EdgeInsets.all(12.r),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Summary', style: Theme.of(context).textTheme.titleMedium),
            SizedBox(height: 8.h),
            _row(
              'Parses',
              'first ${agg.firstPassParses} / retry ${agg.retryParses} / '
                  'fallback ${agg.fallbacks} / err ${agg.errors}',
            ),
            _row(
              'Entity P / R / F1',
              '${_pct(agg.entityPrecision)} / ${_pct(agg.entityRecall)} / '
                  '${_pct(agg.entityF1)}',
            ),
            _row('Entity type accuracy', _pct(agg.typeAccuracy)),
            _row('Cleaned word F1 (mean)', _pct(agg.meanWordF1)),
            _row(
              'Cleaned length ratio (mean)',
              agg.meanLengthRatio.toStringAsFixed(2),
            ),
            _row('Cleaned exact matches', '${agg.exactMatches} / ${agg.cases}'),
          ],
        ),
      ),
    );
  }

  Widget _row(String label, String value) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: 2.h),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 200.w, child: Text(label)),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _pct(double v) => '${(v * 100).toStringAsFixed(1)}%';
}

class _CaseList extends StatelessWidget {
  const _CaseList({required this.state});

  final RefineEvalState state;

  @override
  Widget build(BuildContext context) {
    if (state.results.isEmpty && !state.running) {
      return Center(
        child: Padding(
          padding: EdgeInsets.all(24.r),
          child: const Text(
            'No results yet. Press Run to evaluate the bundled fixture.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    return ListView.builder(
      itemCount: state.results.length,
      itemBuilder: (context, i) {
        final result = state.results[i];
        final fixture = state.cases.firstWhere((c) => c.id == result.caseId);
        return _CaseTile(fixture: fixture, result: result);
      },
    );
  }
}

class _CaseTile extends StatelessWidget {
  const _CaseTile({required this.fixture, required this.result});

  final RefineEvalCase fixture;
  final RefineEvalCaseResult result;

  @override
  Widget build(BuildContext context) {
    final m = result.entityMetrics;
    final c = result.cleanedTextMetrics;
    return ExpansionTile(
      leading: _StatusBadge(status: result.parseStatus),
      title: Text(
        result.caseId,
        style: const TextStyle(fontFamily: 'IBMPlexMono'),
      ),
      subtitle: Text(
        'ent F1 ${_pct(m.f1)} • type ${_pct(m.typeAccuracy)} • '
        'word F1 ${_pct(c.wordF1)} • ${result.elapsed.inMilliseconds} ms',
      ),
      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      expandedCrossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (result.error != null)
          Padding(
            padding: EdgeInsets.only(bottom: 8.h),
            child: Text(
              'Error: ${result.error}',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        _section('Raw transcript', fixture.rawTranscript),
        _section('Expected cleaned', fixture.expectedCleanedText),
        _section('Predicted cleaned', result.predictedCleanedText),
        SizedBox(height: 8.h),
        Text(
          'Expected entities (${fixture.expectedEntities.length})',
          style: Theme.of(context).textTheme.labelMedium,
        ),
        _entityList(fixture.expectedEntities),
        SizedBox(height: 4.h),
        Text(
          'Predicted entities (${result.predictedEntities.length})',
          style: Theme.of(context).textTheme.labelMedium,
        ),
        _entityList(result.predictedEntities),
        SizedBox(height: 6.h),
        Text(
          'Phenomena: ${fixture.phenomena.join(", ")}',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }

  Widget _section(String label, String body) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: 4.h),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
          SizedBox(height: 2.h),
          SelectableText(body),
        ],
      ),
    );
  }

  Widget _entityList(List<RefineEvalEntity> entities) {
    if (entities.isEmpty) {
      return Padding(
        padding: EdgeInsets.symmetric(vertical: 4.h),
        child: const Text('—', style: TextStyle(color: Colors.grey)),
      );
    }
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      children: [
        for (final e in entities)
          Chip(
            visualDensity: VisualDensity.compact,
            label: Text('${e.type}: ${e.text}'),
          ),
      ],
    );
  }

  String _pct(double v) => '${(v * 100).toStringAsFixed(0)}%';
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.status});

  final RefineParseStatus status;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (color, label) = switch (status) {
      RefineParseStatus.firstPass => (scheme.primary, '1st'),
      RefineParseStatus.retry => (scheme.tertiary, 'rty'),
      RefineParseStatus.fallback => (scheme.error, 'fb'),
      RefineParseStatus.generationError => (scheme.error, 'err'),
    };
    return Container(
      width: 36.w,
      height: 28.h,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(6.r),
        border: Border.all(color: color),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 12.sp,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
