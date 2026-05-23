import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voxsynth/features/home/auto_record_provider.dart';
import 'package:voxsynth/features/onboarding/onboarding_flow_screen.dart';
import 'package:voxsynth/features/onboarding/onboarding_screen_data.dart';
import 'package:voxsynth/features/onboarding/onboarding_widgets.dart';

void main() {
  late _TestOnboardingNotifier onboardingNotifier;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    onboardingNotifier = _TestOnboardingNotifier();
  });

  Widget buildTestableWidget(Widget child) {
    return ProviderScope(
      overrides: [
        onboardingCompleteProvider.overrideWith((ref) => onboardingNotifier),
      ],
      child: ScreenUtilInit(
        designSize: const Size(440, 956),
        minTextAdapt: true,
        splitScreenMode: true,
        builder: (context, _) => MaterialApp(home: child),
      ),
    );
  }

  void setupScreenSize(WidgetTester tester) {
    tester.view.physicalSize = const Size(440, 956);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Future<void> pumpForDuration(WidgetTester tester, Duration duration) async {
    final int iterations = (duration.inMilliseconds / 50).ceil();
    for (int i = 0; i < iterations; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  testWidgets('OnboardingFlowScreen renders first page correctly', (
    tester,
  ) async {
    setupScreenSize(tester);
    await tester.pumpWidget(buildTestableWidget(const OnboardingFlowScreen()));
    await tester.pump(const Duration(milliseconds: 100));

    // Verify first screen content
    expect(find.text('Think out loud. Privately.'), findsOneWidget);
    expect(
      find.textContaining(
        'Record your thoughts, ideas, tasks, and reflections',
      ),
      findsOneWidget,
    );
    expect(find.text('Skip'), findsOneWidget);
    expect(find.text('Continue'), findsOneWidget);
  });

  testWidgets('OnboardingFlowScreen page progression via CTA button works', (
    tester,
  ) async {
    setupScreenSize(tester);
    await tester.pumpWidget(buildTestableWidget(const OnboardingFlowScreen()));
    await tester.pump(const Duration(milliseconds: 100));

    // Loop through screens 1 to 5 to verify text and CTA button progression
    for (int i = 0; i < 5; i++) {
      final data = onboardingScreens[i];
      expect(find.text(data.title), findsOneWidget);
      expect(find.text(data.ctaText), findsOneWidget);

      // Tap on PrimaryButton
      await tester.tap(find.byType(PrimaryButton));
      await pumpForDuration(tester, const Duration(milliseconds: 800));
    }

    // Verify final screen content
    final finalData = onboardingScreens[5];
    expect(find.text(finalData.title), findsOneWidget);
    expect(find.text(finalData.ctaText), findsOneWidget);
    expect(find.text('Maybe later'), findsOneWidget);

    // Verify skip button is hidden (opacity is 0)
    final opacityWidget = tester.widget<AnimatedOpacity>(
      find.byType(AnimatedOpacity),
    );
    expect(opacityWidget.opacity, 0.0);
  });

  testWidgets(
    'OnboardingFlowScreen skip button jumps to final page instantly',
    (tester) async {
      setupScreenSize(tester);
      await tester.pumpWidget(
        buildTestableWidget(const OnboardingFlowScreen()),
      );
      await tester.pump(const Duration(milliseconds: 100));

      // Verify we are on first screen
      expect(find.text('Think out loud. Privately.'), findsOneWidget);

      // Tap Skip button
      await tester.tap(find.text('Skip'));
      await pumpForDuration(tester, const Duration(milliseconds: 1000));

      // Verify we are now on final screen
      expect(find.text('Start with your voice'), findsOneWidget);
      expect(find.text('Start recording privately'), findsOneWidget);
      expect(find.text('Maybe later'), findsOneWidget);

      // Verify skip button is hidden (opacity is 0)
      final opacityWidget = tester.widget<AnimatedOpacity>(
        find.byType(AnimatedOpacity),
      );
      expect(opacityWidget.opacity, 0.0);
    },
  );

  testWidgets('Maybe later button marks onboarding complete', (tester) async {
    setupScreenSize(tester);
    await tester.pumpWidget(buildTestableWidget(const OnboardingFlowScreen()));
    await tester.pump(const Duration(milliseconds: 100));

    // Skip to final page
    await tester.tap(find.text('Skip'));
    await pumpForDuration(tester, const Duration(milliseconds: 1000));

    expect(onboardingNotifier.isCompleted, isFalse);

    // Tap "Maybe later"
    await tester.tap(find.text('Maybe later'));
    await tester.pump(const Duration(milliseconds: 100));

    // Verify it called markComplete
    expect(onboardingNotifier.isCompleted, isTrue);
  });
}

class _TestOnboardingNotifier extends OnboardingCompleteNotifier {
  _TestOnboardingNotifier() {
    state = const AsyncValue.data(false);
  }

  bool isCompleted = false;

  @override
  Future<void> markComplete() async {
    isCompleted = true;
    state = const AsyncValue.data(true);
  }
}
