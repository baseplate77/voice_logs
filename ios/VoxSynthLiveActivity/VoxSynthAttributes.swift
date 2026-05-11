import ActivityKit
import Foundation

struct VoxSynthAttributes: ActivityAttributes {
  struct ContentState: Codable, Hashable {
    var elapsedSeconds: Int
    var startedAtMillis: Int64
    var isTranscribing: Bool
    var waveformLevels: [Double]
  }
}
