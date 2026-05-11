import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _kAutoRecordEnabled = 'auto_record_enabled';
const _kOnboardingComplete = 'onboarding_complete';

/// Whether the app should auto-start recording on cold launch.
/// Defaults to `true`.
final autoRecordEnabledProvider =
    StateNotifierProvider<AutoRecordEnabledNotifier, bool>((ref) {
      ref.keepAlive();
      return AutoRecordEnabledNotifier();
    });

class AutoRecordEnabledNotifier extends StateNotifier<bool> {
  AutoRecordEnabledNotifier() : super(true) {
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    state = prefs.getBool(_kAutoRecordEnabled) ?? true;
  }

  Future<void> toggle() async {
    state = !state;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kAutoRecordEnabled, state);
  }
}

/// Whether the user has completed the first-launch onboarding
/// (microphone permission grant).
final onboardingCompleteProvider =
    StateNotifierProvider<OnboardingCompleteNotifier, AsyncValue<bool>>((ref) {
      ref.keepAlive();
      return OnboardingCompleteNotifier();
    });

class OnboardingCompleteNotifier extends StateNotifier<AsyncValue<bool>> {
  OnboardingCompleteNotifier() : super(const AsyncValue.loading()) {
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    state = AsyncValue.data(prefs.getBool(_kOnboardingComplete) ?? false);
  }

  Future<void> markComplete() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kOnboardingComplete, true);
    state = const AsyncValue.data(true);
  }
}
