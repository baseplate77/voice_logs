enum OnboardingVisualType {
  voiceOrb,
  privacyDevice,
  aiPipeline,
  naturalSearch,
  localChat,
  recordButton,
}

class OnboardingScreenData {
  final String title;
  final String subtitle;
  final String ctaText;
  final String? secondaryCtaText;
  final OnboardingVisualType visualType;

  const OnboardingScreenData({
    required this.title,
    required this.subtitle,
    required this.ctaText,
    this.secondaryCtaText,
    required this.visualType,
  });
}

const List<OnboardingScreenData> onboardingScreens = [
  OnboardingScreenData(
    title: 'Think out loud. Privately.',
    subtitle:
        'Record your thoughts, ideas, tasks, and reflections the moment they come to you.',
    ctaText: 'Continue',
    visualType: OnboardingVisualType.voiceOrb,
  ),
  OnboardingScreenData(
    title: 'Your thoughts never leave your device',
    subtitle:
        'Audio, transcripts, summaries, search, and AI chats all stay local. No cloud AI. No training. No data center storage.',
    ctaText: 'See how privacy works',
    visualType: OnboardingVisualType.privacyDevice,
  ),
  OnboardingScreenData(
    title: 'Local AI turns voice into clarity',
    subtitle:
        'Your voice logs are transcribed, cleaned, summarized, and labeled using models running on your device.',
    ctaText: 'Explore local AI',
    visualType: OnboardingVisualType.aiPipeline,
  ),
  OnboardingScreenData(
    title: 'Search like you’re talking to your memory',
    subtitle:
        'Find old logs by asking naturally, like “What ideas did I have about work?” or “Show notes where I felt stressed.”',
    ctaText: 'Try private search',
    visualType: OnboardingVisualType.naturalSearch,
  ),
  OnboardingScreenData(
    title: 'Ask questions across your logs',
    subtitle:
        'Chat with your own local LLM to summarize patterns, find action items, reconnect old ideas, and understand your thoughts.',
    ctaText: 'Meet your local AI',
    visualType: OnboardingVisualType.localChat,
  ),
  OnboardingScreenData(
    title: 'Start with your voice',
    subtitle:
        'Allow microphone access to record your first private log. Audio is processed locally and only when you choose to record.',
    ctaText: 'Start recording privately',
    secondaryCtaText: 'Maybe later',
    visualType: OnboardingVisualType.recordButton,
  ),
];
