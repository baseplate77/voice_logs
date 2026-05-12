/// Typed actions emitted by native intents, URL schemes, and Live Activity
/// taps.
sealed class VoxIntentAction {
  const VoxIntentAction();

  /// Parses the wire action string sent over `IntentBridge`.
  static VoxIntentAction? parse(String raw) {
    final action = raw.trim();
    if (action.isEmpty) return null;

    return switch (action) {
      'start' => const StartRecordingAction(),
      'stop' => const StopRecordingAction(),
      'open' => const OpenAppAction(),
      _ when action.startsWith('openLog:') => _parseOpenLog(action),
      _ => null,
    };
  }

  static VoxIntentAction? _parseOpenLog(String action) {
    final encodedId = action.substring('openLog:'.length);
    if (encodedId.isEmpty) return null;
    final String logId;
    try {
      logId = Uri.decodeComponent(encodedId).trim();
    } on ArgumentError {
      return null;
    }
    if (logId.isEmpty) return null;
    return OpenVoiceLogAction(logId);
  }
}

/// Start recording.
final class StartRecordingAction extends VoxIntentAction {
  const StartRecordingAction();
}

/// Stop the current recording.
final class StopRecordingAction extends VoxIntentAction {
  const StopRecordingAction();
}

/// Open the app without additional navigation.
final class OpenAppAction extends VoxIntentAction {
  const OpenAppAction();
}

/// Open a saved voice log.
final class OpenVoiceLogAction extends VoxIntentAction {
  const OpenVoiceLogAction(this.logId);

  /// The voice log id to display.
  final String logId;
}
