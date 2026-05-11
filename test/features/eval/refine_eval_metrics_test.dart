import 'package:flutter_test/flutter_test.dart';
import 'package:voxsynth/features/eval/refine_eval_case.dart';
import 'package:voxsynth/features/eval/refine_eval_metrics.dart';

void main() {
  group('computeEntityMetrics', () {
    test('exact match yields P=R=F1=1 and full type accuracy', () {
      final m = computeEntityMetrics(
        expected: const [
          RefineEvalEntity(text: 'Shivani', type: 'PERSON'),
          RefineEvalEntity(text: 'Cafe Coffee Day', type: 'PLACE'),
        ],
        predicted: const [
          RefineEvalEntity(text: 'Shivani', type: 'PERSON'),
          RefineEvalEntity(text: 'Cafe Coffee Day', type: 'PLACE'),
        ],
      );
      expect(m.precision, 1.0);
      expect(m.recall, 1.0);
      expect(m.f1, 1.0);
      expect(m.typeAccuracy, 1.0);
    });

    test('case + whitespace insensitive on text', () {
      final m = computeEntityMetrics(
        expected: const [RefineEvalEntity(text: 'Shivani', type: 'PERSON')],
        predicted: const [RefineEvalEntity(text: '  shivani ', type: 'PERSON')],
      );
      expect(m.textMatched, 1);
      expect(m.typeMatched, 1);
    });

    test('text match without type match counts P/R but not type accuracy', () {
      final m = computeEntityMetrics(
        expected: const [RefineEvalEntity(text: 'Monday', type: 'TIME')],
        predicted: const [RefineEvalEntity(text: 'Monday', type: 'OTHER')],
      );
      expect(m.textMatched, 1);
      expect(m.typeMatched, 0);
      expect(m.precision, 1.0);
      expect(m.typeAccuracy, 0.0);
    });

    test('hallucinations drop precision but not recall', () {
      final m = computeEntityMetrics(
        expected: const [RefineEvalEntity(text: 'Shivani', type: 'PERSON')],
        predicted: const [
          RefineEvalEntity(text: 'Shivani', type: 'PERSON'),
          RefineEvalEntity(text: 'Bob', type: 'PERSON'),
          RefineEvalEntity(text: 'Carol', type: 'PERSON'),
        ],
      );
      expect(m.recall, 1.0);
      expect(m.precision, closeTo(1 / 3, 1e-9));
    });

    test('duplicates in prediction match expected once each', () {
      final m = computeEntityMetrics(
        expected: const [
          RefineEvalEntity(text: 'Monday', type: 'TIME'),
          RefineEvalEntity(text: 'Tuesday', type: 'TIME'),
        ],
        predicted: const [
          RefineEvalEntity(text: 'Monday', type: 'TIME'),
          RefineEvalEntity(text: 'Monday', type: 'TIME'),
        ],
      );
      expect(m.textMatched, 1);
      expect(m.predictedCount, 2);
    });
  });

  group('computeCleanedTextMetrics', () {
    test('identical text gives F1 1 and length ratio 1', () {
      const s = 'I met Shivani at Cafe Coffee Day.';
      final m = computeCleanedTextMetrics(expected: s, predicted: s);
      expect(m.wordF1, 1.0);
      expect(m.lengthRatio, 1.0);
      expect(m.exactMatch, isTrue);
    });

    test('punctuation differences ignored by word F1', () {
      final m = computeCleanedTextMetrics(
        expected: 'I met Shivani.',
        predicted: 'i met shivani',
      );
      expect(m.wordF1, 1.0);
      expect(m.exactMatch, isFalse);
    });

    test('summarization shows up as low length ratio', () {
      final m = computeCleanedTextMetrics(
        expected: 'I met Shivani at Cafe Coffee Day around three PM today.',
        predicted: 'Met Shivani.',
      );
      expect(m.lengthRatio, lessThan(0.4));
      expect(m.wordF1, lessThan(0.5));
    });
  });

  group('aggregate', () {
    test('aggregates parse buckets and micro-averaged P/R', () {
      final results = [
        _result(
          'a',
          RefineParseStatus.firstPass,
          entity: const EntityMetrics(
            predictedCount: 2,
            expectedCount: 2,
            textMatched: 2,
            typeMatched: 2,
          ),
          wordF1: 0.9,
          ratio: 1.0,
          exact: true,
        ),
        _result(
          'b',
          RefineParseStatus.retry,
          entity: const EntityMetrics(
            predictedCount: 4,
            expectedCount: 2,
            textMatched: 1,
            typeMatched: 0,
          ),
          wordF1: 0.5,
          ratio: 1.5,
          exact: false,
        ),
      ];
      final agg = aggregate(results);
      expect(agg.cases, 2);
      expect(agg.firstPassParses, 1);
      expect(agg.retryParses, 1);
      expect(agg.entityPrecision, closeTo(3 / 6, 1e-9));
      expect(agg.entityRecall, closeTo(3 / 4, 1e-9));
      expect(agg.typeAccuracy, closeTo(2 / 3, 1e-9));
      expect(agg.meanWordF1, closeTo(0.7, 1e-9));
      expect(agg.exactMatches, 1);
    });
  });
}

RefineEvalCaseResult _result(
  String id,
  RefineParseStatus status, {
  required EntityMetrics entity,
  required double wordF1,
  required double ratio,
  required bool exact,
}) {
  return RefineEvalCaseResult(
    caseId: id,
    parseStatus: status,
    predictedCleanedText: '',
    predictedEntities: const [],
    entityMetrics: entity,
    cleanedTextMetrics: CleanedTextMetrics(
      wordF1: wordF1,
      lengthRatio: ratio,
      exactMatch: exact,
      predictedWordCount: 0,
      expectedWordCount: 0,
    ),
    elapsed: Duration.zero,
  );
}
