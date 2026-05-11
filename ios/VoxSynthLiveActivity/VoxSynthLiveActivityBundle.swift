import SwiftUI
import WidgetKit

@available(iOS 16.1, *)
@main
struct VoxSynthLiveActivityBundle: WidgetBundle {
  var body: some Widget {
    VoxSynthLiveActivity()
    if #available(iOS 18.0, *) {
      VoxSynthRecordControl()
    }
  }
}
