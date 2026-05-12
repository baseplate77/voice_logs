import ActivityKit
import AppIntents
import Foundation

/// Plain Swift bridge from `VoxSynthStartLiveActivityIntent` (compiled into
/// the widget extension) into the main app process. `AppDelegate` sets
/// `handler` during `didFinishLaunchingWithOptions`; the widget extension
/// can't reference `AppDelegate` directly, so it dispatches through this
/// shared symbol instead.
///
/// In the widget extension's own process this stays `nil` and the intent
/// degrades to a Live-Activity-only experience; in the main app process
/// (which iOS launches in background to service the intent) it routes the
/// action into the Flutter recording pipeline.
@available(iOS 18.0, *)
enum IntentActionBridge {
  static var handler: ((String) -> Void)?
}

/// Live Activity starting intent used by the Control Widget Action Button.
///
/// `LiveActivityStartingIntent` (iOS 18+) is the only documented way to call
/// `Activity.request(...)` from a background-launched context — plain
/// `AppIntent`s trip "Target is not foreground" because ActivityKit requires
/// foreground for `Activity.request`. By conforming to this protocol the
/// system grants the intent the runtime context needed to start a Live
/// Activity without bringing the app to the foreground.
///
/// The Siri shortcut path goes through the separate `StartRecordingIntent`
/// in the Runner target, which is foreground-only and so doesn't need this
/// protocol.
@available(iOS 18.0, *)
struct VoxSynthStartLiveActivityIntent: LiveActivityStartingIntent {
  static var title: LocalizedStringResource = "Start Voice Log"
  static var description = IntentDescription("Start recording a voice log in VoxSynth")
  // Opening the app is required because only the Flutter app owns the real
  // audio recorder. A Live Activity without the Flutter recording controller
  // is just a visual shell and will not produce a saved voice log.
  static var openAppWhenRun: Bool = true

  func perform() async throws -> some IntentResult {
    // Start the Live Activity from within the intent's execution context.
    // `LiveActivityStartingIntent` is the protocol that authorizes this call
    // from background.
    await Self.startLiveActivity()

    // Forward the start action into the host app if it's reachable so the
    // Flutter pipeline can capture audio and own the activity's state.
    if let dispatch = IntentActionBridge.handler {
      await MainActor.run {
        dispatch("start")
      }
    }
    return .result()
  }

  @MainActor
  private static func startLiveActivity() async {
    guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
    // Don't stack duplicates; the channel-side adopt-via-update path handles
    // any later state mutations from Flutter.
    if !Activity<VoxSynthAttributes>.activities.isEmpty { return }

    let now = Date()
    let state = VoxSynthAttributes.ContentState(
      elapsedSeconds: 0,
      startedAtMillis: Int64(now.timeIntervalSince1970 * 1000),
      phase: "recording",
      isTranscribing: false,
      waveformLevels: []
    )
    let content = ActivityContent(state: state, staleDate: nil)
    _ = try? Activity.request(attributes: VoxSynthAttributes(), content: content)
  }
}
