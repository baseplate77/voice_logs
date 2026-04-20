import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:voxsynth/synth/background/models/daily_brief.dart';
import 'package:voxsynth/synth/background/models/monthly_shifts.dart';
import 'package:voxsynth/synth/background/models/weekly_themes.dart';

void main() {
  group('DailyBrief JSON round-trip', () {
    test('encodes and decodes identically', () {
      const original = DailyBrief(
        date: '2026-04-19',
        summary: 'Light day. Focus on pricing.',
        actionItems: <DailyActionItem>[
          DailyActionItem(
            text: 'Send proposal by Friday',
            sourceChunkIds: <int>[1, 3],
          ),
        ],
        keyMoments: <DailyKeyMoment>[
          DailyKeyMoment(
            description: 'Decided on the 3-tier pricing',
            sourceChunkIds: <int>[2],
          ),
        ],
      );
      final encoded = jsonEncode(original.toJson());
      final decoded = DailyBrief.fromJson(
        jsonDecode(encoded) as Map<String, Object?>,
      );
      expect(decoded, original);
    });

    test('empty collections round-trip', () {
      const empty = DailyBrief(
        date: '2026-04-19',
        summary: 'No activity.',
        actionItems: <DailyActionItem>[],
        keyMoments: <DailyKeyMoment>[],
      );
      final decoded = DailyBrief.fromJson(
        jsonDecode(jsonEncode(empty.toJson())) as Map<String, Object?>,
      );
      expect(decoded, empty);
    });
  });

  group('WeeklyThemes JSON round-trip', () {
    test('encodes and decodes identically', () {
      const original = WeeklyThemes(
        weekStart: '2026-04-13',
        themes: <WeeklyTheme>[
          WeeklyTheme(
            title: 'Pricing revisions',
            summary: 'You revisited pricing three times.',
            supportingChunkIds: <int>[1, 2, 3],
          ),
        ],
        contradictions: <WeeklyContradiction>[
          WeeklyContradiction(
            earlierPosition: 'Flat rate',
            laterPosition: 'Tiered',
            earlierChunkIds: <int>[1],
            laterChunkIds: <int>[3],
          ),
        ],
      );
      final decoded = WeeklyThemes.fromJson(
        jsonDecode(jsonEncode(original.toJson())) as Map<String, Object?>,
      );
      expect(decoded, original);
    });
  });

  group('MonthlyShifts JSON round-trip', () {
    test('encodes and decodes identically', () {
      const original = MonthlyShifts(
        monthStart: '2026-04-02',
        headline: 'Pricing solidified, team dynamics shifted.',
        shifts: <MonthlyShift>[
          MonthlyShift(
            topic: 'Pricing',
            priorSummary: 'Uncertain, multiple models considered',
            currentSummary: 'Settled on tiered',
            priorChunkIds: <int>[10, 11],
            currentChunkIds: <int>[40, 41],
          ),
        ],
      );
      final decoded = MonthlyShifts.fromJson(
        jsonDecode(jsonEncode(original.toJson())) as Map<String, Object?>,
      );
      expect(decoded, original);
    });
  });
}
