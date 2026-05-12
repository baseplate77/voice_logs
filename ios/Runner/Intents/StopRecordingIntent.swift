import AppIntents
import UIKit

@available(iOS 16.4, *)
struct StopRecordingIntent: AppIntent {
  static var title: LocalizedStringResource = "Stop Voice Log"
  static var description = IntentDescription("Stop the current recording in VoxSynth")
  static var openAppWhenRun: Bool = true
  static var authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

  func perform() async throws -> some IntentResult {
    let dispatched = await MainActor.run { () -> Bool in
      guard let delegate = UIApplication.shared.delegate as? AppDelegate else {
        return false
      }
      delegate.dispatchIntentAction("stop")
      return true
    }
    if !dispatched {
      PendingIntentStore.append("stop")
    }
    return .result()
  }
}
