import AppIntents
import SwiftUI
import WidgetKit

@available(iOS 18.0, *)
struct VoxSynthRecordControl: ControlWidget {
  var body: some ControlWidgetConfiguration {
    StaticControlConfiguration(kind: "com.nj.voxsynth.record-control") {
      ControlWidgetButton(action: OpenURLIntent(URL(string: "voxsynth://start")!)) {
        Label("Record", systemImage: "mic.fill")
      }
    }
    .displayName("Start Voice Log")
    .description("Start recording a voice log.")
  }
}
