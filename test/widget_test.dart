import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voxsynth/app.dart';
import 'package:voxsynth/core/db/providers.dart';

void main() {
  testWidgets('VoxSynthApp boots and shows onboarding copy when empty', (
    tester,
  ) async {
    // Override the stream provider so the widget tree never touches a
    // real DB in the test harness.
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          voiceLogsStreamProvider.overrideWith((_) => Stream.value(const [])),
        ],
        child: const VoxSynthApp(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('VoxSynth'), findsOneWidget);
    expect(find.textContaining('smarter'), findsOneWidget);
  });
}
