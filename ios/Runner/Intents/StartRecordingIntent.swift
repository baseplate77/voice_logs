import AppIntents
import UIKit

@available(iOS 16.4, *)
struct StartRecordingIntent: AppIntent {
  static var title: LocalizedStringResource = "Start Voice Log"
  static var description = IntentDescription("Start recording a voice log in VoxSynth")
  static var openAppWhenRun: Bool = true
  static var authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

  func perform() async throws -> some IntentResult {
    if let delegate = await UIApplication.shared.delegate as? AppDelegate {
      await MainActor.run {
        delegate.dispatchIntentAction("start")
      }
    }
    return .result()
  }
}
