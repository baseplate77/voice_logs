import ActivityKit
import SwiftUI
import WidgetKit

@available(iOS 16.1, *)
struct VoxSynthLiveActivity: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: VoxSynthAttributes.self) { context in
      lockScreenView(context: context)
    } dynamicIsland: { context in
      DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          Image(systemName: "mic.fill")
            .foregroundColor(.red)
            .font(.title2)
        }
        DynamicIslandExpandedRegion(.center) {
          VStack(spacing: 6) {
            timerText(context.state)
              .font(.title2.weight(.semibold))
              .monospacedDigit()
              .lineLimit(1)
              .minimumScaleFactor(0.7)
            waveformView(
              levels: context.state.waveformLevels,
              height: 18,
              color: context.state.isTranscribing ? .orange : .red
            )
            .frame(width: 104)
          }
        }
        DynamicIslandExpandedRegion(.trailing) {
          if context.state.isTranscribing {
            ProgressView()
              .tint(.white)
          } else {
            Link(destination: URL(string: "voxsynth://stop")!) {
              Image(systemName: "stop.circle.fill")
                .font(.title2)
                .foregroundColor(.white)
            }
          }
        }
      } compactLeading: {
        Image(systemName: "mic.fill")
          .foregroundColor(.red)
      } compactTrailing: {
        timerText(context.state)
          .font(.caption2.weight(.semibold))
          .monospacedDigit()
          .lineLimit(1)
          .minimumScaleFactor(0.7)
      } minimal: {
        Image(systemName: "mic.fill")
          .foregroundColor(.red)
      }
    }
  }

  @ViewBuilder
  private func lockScreenView(context: ActivityViewContext<VoxSynthAttributes>) -> some View {
    HStack(spacing: 16) {
      Image(systemName: "mic.fill")
        .font(.title)
        .foregroundColor(.red)

      VStack(alignment: .leading, spacing: 8) {
        Text(context.state.isTranscribing ? "Transcribing..." : "Recording")
          .font(.headline)
          .foregroundStyle(.primary)
        timerText(context.state)
          .font(.title2.weight(.semibold))
          .monospacedDigit()
          .lineLimit(1)
          .minimumScaleFactor(0.8)
          .foregroundStyle(.primary)
        waveformView(
          levels: context.state.waveformLevels,
          height: 30,
          color: context.state.isTranscribing ? .orange : .red
        )
        .frame(width: 168)
      }

      Spacer()

      if context.state.isTranscribing {
        ProgressView()
          .tint(.primary)
      } else {
        Link(destination: URL(string: "voxsynth://stop")!) {
          Image(systemName: "stop.circle.fill")
            .font(.largeTitle)
            .foregroundColor(.red)
        }
      }
    }
    .padding()
    .activityBackgroundTint(Color(.systemBackground))
    .activitySystemActionForegroundColor(.red)
  }

  @ViewBuilder
  private func waveformView(levels: [Double], height: CGFloat, color: Color) -> some View {
    let bars = normalizedLevels(levels)
    HStack(alignment: .center, spacing: 3) {
      ForEach(Array(bars.enumerated()), id: \.offset) { _, level in
        RoundedRectangle(cornerRadius: 2.5)
          .fill(color.opacity(0.9))
          .frame(width: 5, height: max(6, height * CGFloat(level)))
      }
    }
    .frame(height: height)
    .accessibilityLabel("Audio waveform")
  }

  private func normalizedLevels(_ levels: [Double]) -> [Double] {
    let fallback = [0.24, 0.48, 0.32, 0.68, 0.42, 0.82, 0.36, 0.62, 0.3, 0.54, 0.28, 0.44]
    let source = levels.isEmpty ? fallback : levels
    return source.suffix(12).map { min(1.0, max(0.08, $0)) }
  }

  @ViewBuilder
  private func timerText(_ state: VoxSynthAttributes.ContentState) -> some View {
    if state.isTranscribing || state.startedAtMillis <= 0 {
      Text(formatTime(state.elapsedSeconds))
    } else {
      Text(recordingStartedDate(state), style: .timer)
    }
  }

  private func recordingStartedDate(_ state: VoxSynthAttributes.ContentState) -> Date {
    Date(timeIntervalSince1970: TimeInterval(state.startedAtMillis) / 1000.0)
  }

  private func formatTime(_ totalSeconds: Int) -> String {
    let minutes = totalSeconds / 60
    let seconds = totalSeconds % 60
    return String(format: "%02d:%02d", minutes, seconds)
  }
}
