import AppIntents
import UIKit

@available(iOS 16.4, *)
struct StopRecordingIntent: AppIntent {
  static var title: LocalizedStringResource = "Stop Voice Log"
  static var description = IntentDescription("Stop the current recording in VoxSynth")
  static var openAppWhenRun: Bool = true
  static var authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

  func perform() async throws -> some IntentResult {
    if let delegate = await UIApplication.shared.delegate as? AppDelegate {
      await MainActor.run {
        delegate.dispatchIntentAction("stop")
      }
    }
    return .result()
  }
}
