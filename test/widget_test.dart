import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voxsynth/app.dart';

void main() {
  testWidgets('VoxSynthApp boots and shows onboarding copy', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: VoxSynthApp()));
    await tester.pumpAndSettle();

    expect(find.text('VoxSynth'), findsOneWidget);
    expect(find.textContaining('smarter'), findsOneWidget);
  });
}
