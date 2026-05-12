import AppIntents
import UIKit

/// Durable fallback for AppIntent actions that run before `AppDelegate` is
/// reachable. Flutter drains this through the native `getPendingActions`
/// method on startup/resume.
enum PendingIntentStore {
  private static let key = "com.nj.voxsynth.pendingIntentActions"

  static func append(_ action: String) {
    guard !action.isEmpty else { return }
    let defaults = UserDefaults.standard
    var actions = defaults.stringArray(forKey: key) ?? []
    actions.append(action)
    defaults.set(actions, forKey: key)
  }

  static func consumeAll() -> [String] {
    let defaults = UserDefaults.standard
    let actions = defaults.stringArray(forKey: key) ?? []
    defaults.removeObject(forKey: key)
    return actions
  }
}

/// Siri / hardware Action Button shortcut to start recording. The app opens
/// so Flutter can show the home recording overlay and own the real recorder.
@available(iOS 16.4, *)
struct StartRecordingIntent: AppIntent {
  static var title: LocalizedStringResource = "Start Voice Log"
  static var description = IntentDescription("Start recording a voice log in VoxSynth")
  static var openAppWhenRun: Bool = true
  static var authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

  func perform() async throws -> some IntentResult {
    let dispatched = await MainActor.run { () -> Bool in
      guard let delegate = UIApplication.shared.delegate as? AppDelegate else {
        return false
      }
      delegate.dispatchIntentAction("start")
      return true
    }
    if !dispatched {
      PendingIntentStore.append("start")
    }
    return .result()
  }
}
