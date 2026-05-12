import ActivityKit
import Foundation
import SwiftUI
import WidgetKit

@available(iOS 16.1, *)
struct VoxSynthLiveActivity: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: VoxSynthAttributes.self) { context in
      lockScreenView(context: context)
        .widgetURL(appURL(for: context.state))
    } dynamicIsland: { context in
      DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          islandLeadingView(context.state)
            .padding(.leading, 2)
        }

        DynamicIslandExpandedRegion(.center) {
          islandCenterView(context.state)
        }

        DynamicIslandExpandedRegion(.trailing) {
          islandTrailingView(context.state)
            .padding(.trailing, 2)
        }

        DynamicIslandExpandedRegion(.bottom) {
          if activityPhase(context.state) == .completed {
            HStack(spacing: 6) {
              Image(systemName: "checkmark.circle.fill")
                .font(.caption2.weight(.semibold))
              Text("Transcript saved on this device")
                .font(.caption2.weight(.medium))
              Spacer(minLength: 8)
              Text("Ready")
                .font(.caption2.weight(.semibold))
            }
            .foregroundStyle(Palette.completed)
            .padding(.horizontal, 2)
          } else if activityPhase(context.state) == .refining {
            HStack(spacing: 6) {
              Image(systemName: "sparkles")
                .font(.caption2.weight(.semibold))
              Text("Refining transcript on-device")
                .font(.caption2.weight(.medium))
              Spacer(minLength: 8)
              Text("Private")
                .font(.caption2.weight(.semibold))
            }
            .foregroundStyle(Palette.refining)
            .padding(.horizontal, 2)
          } else {
            HStack(spacing: 6) {
              Image(systemName: "lock.fill")
                .font(.caption2.weight(.semibold))
              Text("Private voice journal")
                .font(.caption2.weight(.medium))
              Spacer(minLength: 8)
              Text("On-device & private")
                .font(.caption2.weight(.medium))
              Image(systemName: "shield.fill")
                .font(.caption2.weight(.semibold))
            }
            .foregroundStyle(Palette.textSecondary)
            .padding(.horizontal, 2)
          }
        }
      } compactLeading: {
        compactLeadingView(context.state)
      } compactTrailing: {
        compactTrailingView(context.state)
      } minimal: {
        minimalView(context.state)
      }
      .keylineTint(accentColor(context.state))
      .widgetURL(appURL(for: context.state))
    }
  }

  @ViewBuilder
  private func lockScreenView(context: ActivityViewContext<VoxSynthAttributes>) -> some View {
    switch activityPhase(context.state) {
    case .recording:
      recordingLockScreenView(context.state)
    case .transcribing:
      transcribingLockScreenView(context.state)
    case .refining:
      refiningLockScreenView(context.state)
    case .completed:
      completedLockScreenView(context.state)
    }
  }

  private func recordingLockScreenView(_ state: VoxSynthAttributes.ContentState) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      headerView(color: Palette.recording)

      HStack(alignment: .center, spacing: 16) {
        VStack(alignment: .leading, spacing: 10) {
          stateRow(label: "Recording", color: Palette.recording)

          timerText(state)
            .font(.system(size: 54, weight: .bold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(Palette.textPrimary)
            .lineLimit(1)
            .minimumScaleFactor(0.72)
        }

        Spacer(minLength: 10)

        stopButton
      }

      waveformView(
        levels: state.waveformLevels,
        barCount: 32,
        height: 38,
        color: Palette.recording,
        isSubdued: false
      )

      privacyFooter
    }
    .modifier(ActivityCardModifier(accent: Palette.recording))
  }

  private func transcribingLockScreenView(_ state: VoxSynthAttributes.ContentState) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      headerView(color: Palette.transcribing)

      HStack(alignment: .center, spacing: 16) {
        VStack(alignment: .leading, spacing: 10) {
          stateRow(label: "Transcribing", color: Palette.transcribing)

          Text("Transcribing...")
            .font(.system(size: 24, weight: .semibold, design: .rounded))
            .foregroundStyle(Palette.textPrimary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)

          timerText(state)
            .font(.system(size: 54, weight: .bold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(Palette.textPrimary)
            .lineLimit(1)
            .minimumScaleFactor(0.72)
        }

        Spacer(minLength: 10)

        progressRing(size: 58, lineWidth: 6, color: Palette.transcribing)
      }

      waveformView(
        levels: state.waveformLevels,
        barCount: 32,
        height: 22,
        color: Palette.transcribing,
        isSubdued: true
      )

      privacyFooter
    }
    .modifier(ActivityCardModifier(accent: Palette.transcribing))
  }

  private func refiningLockScreenView(_ state: VoxSynthAttributes.ContentState) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      headerView(color: Palette.refining)

      HStack(alignment: .center, spacing: 16) {
        VStack(alignment: .leading, spacing: 10) {
          stateRow(label: "Refining", color: Palette.refining)

          Text("Polishing transcript")
            .font(.system(size: 22, weight: .semibold, design: .rounded))
            .foregroundStyle(Palette.textPrimary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)

          Text("On-device LLM cleanup")
            .font(.system(size: 14, weight: .regular, design: .rounded))
            .foregroundStyle(Palette.textSecondary)
            .lineLimit(1)
        }

        Spacer(minLength: 10)

        sparkleBadge(size: 58, iconSize: 28, color: Palette.refining)
      }

      progressBar(color: Palette.refining)

      privacyFooter
    }
    .modifier(ActivityCardModifier(accent: Palette.refining))
  }

  private func completedLockScreenView(_ state: VoxSynthAttributes.ContentState) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      headerView(color: Palette.completed)

      HStack(alignment: .center, spacing: 16) {
        VStack(alignment: .leading, spacing: 9) {
          stateRow(label: "Ready", color: Palette.completed)

          Text("Transcript saved")
            .font(.system(size: 30, weight: .bold, design: .rounded))
            .foregroundStyle(Palette.textPrimary)
            .lineLimit(1)
            .minimumScaleFactor(0.72)

          Text("Your recording is complete and saved on this device.")
            .font(.system(size: 15, weight: .regular, design: .rounded))
            .foregroundStyle(Palette.textSecondary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
        }

        Spacer(minLength: 10)

        checkmarkBadge(size: 72, iconSize: 38)
      }

      Link(destination: appURL(for: state)) {
        Text("Open")
          .font(.system(size: 17, weight: .semibold, design: .rounded))
          .foregroundStyle(Color.white)
          .frame(width: 108, height: 38)
          .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
              .fill(Palette.completed)
          )
      }
      .accessibilityLabel("Open VoxSynth")

      privacyFooter
    }
    .modifier(ActivityCardModifier(accent: Palette.completed))
  }

  @ViewBuilder
  private func islandLeadingView(_ state: VoxSynthAttributes.ContentState) -> some View {
    switch activityPhase(state) {
    case .recording:
      microphoneBadge(size: 44, iconSize: 21, color: Palette.recording)
    case .transcribing:
      progressRing(size: 44, lineWidth: 5, color: Palette.transcribing)
    case .refining:
      sparkleBadge(size: 44, iconSize: 22, color: Palette.refining)
    case .completed:
      appMark(color: Palette.completed, size: 44, cornerRadius: 22)
    }
  }

  @ViewBuilder
  private func islandCenterView(_ state: VoxSynthAttributes.ContentState) -> some View {
    switch activityPhase(state) {
    case .recording:
      VStack(alignment: .leading, spacing: 6) {
        stateRow(label: "Recording", color: Palette.recording, compact: true)
        waveformView(
          levels: state.waveformLevels,
          barCount: 22,
          height: 20,
          color: Palette.recording,
          isSubdued: false
        )
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    case .transcribing:
      VStack(alignment: .leading, spacing: 6) {
        stateRow(label: "Transcribing", color: Palette.transcribing, compact: true)
        waveformView(
          levels: state.waveformLevels,
          barCount: 22,
          height: 18,
          color: Palette.transcribing,
          isSubdued: true
        )
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    case .refining:
      VStack(alignment: .leading, spacing: 6) {
        stateRow(label: "Refining", color: Palette.refining, compact: true)
        progressBar(color: Palette.refining)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    case .completed:
      HStack(spacing: 8) {
        Text("VoxSynth")
          .font(.system(size: 15, weight: .semibold, design: .rounded))
          .foregroundStyle(Palette.textPrimary)
          .lineLimit(1)
        Image(systemName: "checkmark.circle.fill")
          .font(.system(size: 18, weight: .semibold))
          .foregroundStyle(Palette.completed)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  @ViewBuilder
  private func islandTrailingView(_ state: VoxSynthAttributes.ContentState) -> some View {
    switch activityPhase(state) {
    case .recording, .transcribing:
      timerText(state)
        .font(.system(size: 19, weight: .semibold, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(accentColor(state))
        .lineLimit(1)
        .minimumScaleFactor(0.75)
    case .refining:
      Text("Polishing")
        .font(.system(size: 14, weight: .semibold, design: .rounded))
        .foregroundStyle(Palette.refining)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    case .completed:
      Text("Ready")
        .font(.system(size: 16, weight: .semibold, design: .rounded))
        .foregroundStyle(Palette.completed)
        .lineLimit(1)
    }
  }

  @ViewBuilder
  private func compactLeadingView(_ state: VoxSynthAttributes.ContentState) -> some View {
    switch activityPhase(state) {
    case .recording:
      HStack(alignment: .center, spacing: 7) {
        microphoneBadge(size: 26, iconSize: 13, color: Palette.recording)
        compactWaveformView(levels: state.waveformLevels, color: Palette.recording)
      }
      .padding(.leading, 2)
      .frame(maxHeight: .infinity, alignment: .center)
    case .transcribing:
      progressRing(size: 30, lineWidth: 4, color: Palette.transcribing)
    case .refining:
      sparkleBadge(size: 30, iconSize: 15, color: Palette.refining)
    case .completed:
      checkmarkBadge(size: 30, iconSize: 15)
    }
  }

  private func compactWaveformView(levels: [Double], color: Color) -> some View {
    let bars = normalizedLevels(levels, count: 8)
    return HStack(alignment: .center, spacing: 2.5) {
      ForEach(Array(bars.enumerated()), id: \.offset) { _, level in
        Capsule(style: .continuous)
          .fill(color)
          .frame(width: 2.8, height: max(6, 22 * CGFloat(level)))
      }
    }
    .frame(height: 24)
    .accessibilityLabel("Recording waveform")
  }

  @ViewBuilder
  private func compactTrailingView(_ state: VoxSynthAttributes.ContentState) -> some View {
    switch activityPhase(state) {
    case .recording, .transcribing:
      timerText(state)
        .font(.system(size: 15, weight: .semibold, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(accentColor(state))
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .padding(.trailing, 2)
        .frame(maxHeight: .infinity, alignment: .center)
    case .refining:
      Text("Polish")
        .font(.system(size: 13, weight: .semibold, design: .rounded))
        .foregroundStyle(Palette.refining)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .padding(.trailing, 2)
        .frame(maxHeight: .infinity, alignment: .center)
    case .completed:
      Text("Ready")
        .font(.system(size: 15, weight: .semibold, design: .rounded))
        .foregroundStyle(Palette.completed)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .frame(maxHeight: .infinity, alignment: .center)
    }
  }

  @ViewBuilder
  private func minimalView(_ state: VoxSynthAttributes.ContentState) -> some View {
    switch activityPhase(state) {
    case .recording:
      microphoneBadge(size: 24, iconSize: 12, color: Palette.recording)
    case .transcribing:
      progressRing(size: 24, lineWidth: 3.5, color: Palette.transcribing)
    case .refining:
      sparkleBadge(size: 24, iconSize: 12, color: Palette.refining)
    case .completed:
      checkmarkBadge(size: 24, iconSize: 12)
    }
  }

  private func headerView(color: Color) -> some View {
    HStack(alignment: .center, spacing: 9) {
      appMark(color: color, size: 25, cornerRadius: 7)
      Text("VoxSynth")
        .font(.system(size: 17, weight: .semibold, design: .rounded))
        .foregroundStyle(Palette.textPrimary)
      Spacer()
    }
  }

  private func stateRow(label: String, color: Color, compact: Bool = false) -> some View {
    HStack(spacing: compact ? 6 : 8) {
      Circle()
        .fill(color)
        .frame(width: compact ? 8 : 12, height: compact ? 8 : 12)
        .shadow(color: color.opacity(0.7), radius: compact ? 3 : 5, x: 0, y: 0)
      Text(label)
        .font(compact ? .caption2.weight(.semibold) : .system(size: 15, weight: .medium, design: .rounded))
        .foregroundStyle(compact ? Palette.textSecondary : Palette.textPrimary)
        .lineLimit(1)
    }
  }

  private var privacyFooter: some View {
    HStack(spacing: 6) {
      Image(systemName: "lock.fill")
        .font(.system(size: 12, weight: .semibold))
      Text("Private voice journal")
        .font(.system(size: 13, weight: .regular, design: .rounded))
      Spacer(minLength: 10)
      Text("On-device & private")
        .font(.system(size: 13, weight: .regular, design: .rounded))
      Image(systemName: "shield.fill")
        .font(.system(size: 12, weight: .semibold))
    }
    .foregroundStyle(Palette.textSecondary)
  }

  private var stopButton: some View {
    Link(destination: URL(string: "voxsynth://stop")!) {
      ZStack {
        Circle()
          .fill(Palette.recording)
          .frame(width: 58, height: 58)
          .shadow(color: Palette.recording.opacity(0.45), radius: 16, x: 0, y: 0)
        RoundedRectangle(cornerRadius: 4, style: .continuous)
          .fill(Color.white)
          .frame(width: 18, height: 18)
      }
      .accessibilityLabel("Stop recording")
    }
  }

  private func appMark(color: Color, size: CGFloat, cornerRadius: CGFloat) -> some View {
    ZStack {
      RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        .fill(Palette.surfaceDark)
        .frame(width: size, height: size)
      miniWaveform(color: color, height: size * 0.62)
    }
    .accessibilityHidden(true)
  }

  private func miniWaveform(color: Color, height: CGFloat) -> some View {
    HStack(alignment: .center, spacing: 1.4) {
      ForEach(Array([0.34, 0.58, 0.9, 0.7, 0.44].enumerated()), id: \.offset) { _, level in
        Capsule(style: .continuous)
          .fill(color)
          .frame(width: 2.2, height: height * CGFloat(level))
      }
    }
    .frame(height: height)
  }

  private func microphoneBadge(size: CGFloat, iconSize: CGFloat, color: Color) -> some View {
    ZStack {
      Circle()
        .fill(color.opacity(0.18))
      Image(systemName: "mic.fill")
        .font(.system(size: iconSize, weight: .semibold))
        .foregroundStyle(color)
    }
    .frame(width: size, height: size)
    .accessibilityLabel("Recording")
  }

  private func checkmarkBadge(size: CGFloat, iconSize: CGFloat) -> some View {
    ZStack {
      Circle()
        .fill(Palette.completed)
        .shadow(color: Palette.completed.opacity(0.38), radius: size * 0.22, x: 0, y: 0)
      Image(systemName: "checkmark")
        .font(.system(size: iconSize, weight: .bold))
        .foregroundStyle(Color.white)
    }
    .frame(width: size, height: size)
    .accessibilityLabel("Transcript saved")
  }

  private func sparkleBadge(size: CGFloat, iconSize: CGFloat, color: Color) -> some View {
    ZStack {
      Circle()
        .fill(color.opacity(0.18))
      Image(systemName: "sparkles")
        .font(.system(size: iconSize, weight: .semibold))
        .foregroundStyle(color)
    }
    .frame(width: size, height: size)
    .accessibilityLabel("Refining")
  }

  private func progressBar(color: Color) -> some View {
    GeometryReader { geo in
      ZStack(alignment: .leading) {
        Capsule(style: .continuous)
          .fill(color.opacity(0.18))
        Capsule(style: .continuous)
          .fill(color)
          .frame(width: geo.size.width * 0.42)
      }
    }
    .frame(height: 6)
    .accessibilityLabel("Refining in progress")
  }

  private func progressRing(size: CGFloat, lineWidth: CGFloat, color: Color) -> some View {
    ZStack {
      Circle()
        .stroke(color.opacity(0.22), lineWidth: lineWidth)
      Circle()
        .trim(from: 0.08, to: 0.82)
        .stroke(
          color,
          style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
        )
        .rotationEffect(.degrees(-90))
    }
    .frame(width: size, height: size)
    .accessibilityLabel("Transcribing")
  }

  @ViewBuilder
  private func waveformView(
    levels: [Double],
    barCount: Int,
    height: CGFloat,
    color: Color,
    isSubdued: Bool
  ) -> some View {
    let bars = normalizedLevels(levels, count: barCount)
    HStack(alignment: .center, spacing: 3) {
      ForEach(Array(bars.enumerated()), id: \.offset) { index, level in
        Capsule(style: .continuous)
          .fill(barColor(index: index, count: bars.count, color: color, isSubdued: isSubdued))
          .frame(width: 4, height: max(4, height * CGFloat(level)))
      }
    }
    .frame(height: height)
    .accessibilityLabel("Live audio waveform")
  }

  private func normalizedLevels(_ levels: [Double], count: Int) -> [Double] {
    let fallback = [
      0.30, 0.62, 0.40, 0.82, 0.52, 0.96, 0.34, 0.70,
      0.46, 0.76, 0.38, 0.58, 0.32, 0.50, 0.28, 0.44,
      0.72, 0.88, 0.54, 0.78, 0.36, 0.56, 0.42, 0.66,
      0.30, 0.48, 0.26, 0.36, 0.22, 0.18, 0.14, 0.12
    ]

    let source = levels.isEmpty ? fallback : levels
    let clipped = source.suffix(count).map { min(1.0, max(0.08, $0)) }
    if clipped.count >= count { return Array(clipped) }

    let padding = fallback.prefix(count - clipped.count)
    return Array(padding) + clipped
  }

  private func barColor(index: Int, count: Int, color: Color, isSubdued: Bool) -> Color {
    if isSubdued {
      let fadeStart = max(0, count - 8)
      if index >= fadeStart {
        let distance = Double(index - fadeStart)
        return Palette.textSecondary.opacity(max(0.18, 0.44 - distance * 0.04))
      }
      return color.opacity(0.64)
    }

    guard count > 6, index >= count - 6 else {
      return color.opacity(0.95)
    }
    let distance = Double(index - (count - 6))
    return Palette.textSecondary.opacity(max(0.22, 0.52 - distance * 0.06))
  }

  @ViewBuilder
  private func timerText(_ state: VoxSynthAttributes.ContentState) -> some View {
    if activityPhase(state) != .recording || state.startedAtMillis <= 0 {
      Text(formatTime(state.elapsedSeconds))
    } else {
      Text(recordingStartedDate(state), style: .timer)
    }
  }

  private func recordingStartedDate(_ state: VoxSynthAttributes.ContentState) -> Date {
    Date(timeIntervalSince1970: TimeInterval(state.startedAtMillis) / 1000.0)
  }

  private func activityPhase(_ state: VoxSynthAttributes.ContentState) -> LiveActivityPhase {
    switch state.phase {
    case "completed":
      return .completed
    case "refining":
      return .refining
    case "transcribing":
      return .transcribing
    case "recording":
      return .recording
    default:
      return state.isTranscribing ? .transcribing : .recording
    }
  }

  private func accentColor(_ state: VoxSynthAttributes.ContentState) -> Color {
    switch activityPhase(state) {
    case .recording:
      return Palette.recording
    case .transcribing:
      return Palette.transcribing
    case .refining:
      return Palette.refining
    case .completed:
      return Palette.completed
    }
  }

  private func formatTime(_ totalSeconds: Int) -> String {
    let minutes = totalSeconds / 60
    let seconds = totalSeconds % 60
    return String(format: "%02d:%02d", minutes, seconds)
  }

  private func appURL(for state: VoxSynthAttributes.ContentState) -> URL {
    if let logId = state.logId,
       !logId.isEmpty,
       let encoded = logId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
       let url = URL(string: "voxsynth://log/\(encoded)") {
      return url
    }
    return URL(string: "voxsynth://open")!
  }
}

@available(iOS 16.1, *)
private enum LiveActivityPhase {
  case recording
  case transcribing
  case refining
  case completed
}

@available(iOS 16.1, *)
private struct ActivityCardModifier: ViewModifier {
  let accent: Color

  func body(content: Content) -> some View {
    content
      .padding(.horizontal, 22)
      .padding(.vertical, 20)
      .background(cardBackground)
      .activityBackgroundTint(Palette.surface)
      .activitySystemActionForegroundColor(accent)
  }

  private var cardBackground: some View {
    RoundedRectangle(cornerRadius: 28, style: .continuous)
      .fill(
        LinearGradient(
          colors: [Palette.surface.opacity(0.98), Palette.surfaceElevated.opacity(0.96)],
          startPoint: .topLeading,
          endPoint: .bottomTrailing
        )
      )
      .overlay(
        RoundedRectangle(cornerRadius: 28, style: .continuous)
          .strokeBorder(Palette.divider.opacity(0.85), lineWidth: 1)
      )
  }
}

@available(iOS 16.1, *)
private enum Palette {
  static let recording = Color(red: 1.0, green: 0.35, blue: 0.37)
  static let transcribing = Color(red: 1.0, green: 0.69, blue: 0.13)
  static let refining = Color(red: 0.62, green: 0.42, blue: 0.95)
  static let completed = Color(red: 0.0, green: 0.78, blue: 0.65)
  static let surfaceDark = Color(red: 0.05, green: 0.05, blue: 0.06)
  static let surface = Color(red: 0.05, green: 0.05, blue: 0.06)
  static let surfaceElevated = Color(red: 0.11, green: 0.11, blue: 0.12)
  static let textPrimary = Color(red: 0.95, green: 0.96, blue: 0.98)
  static let textSecondary = Color(red: 0.56, green: 0.59, blue: 0.64)
  static let divider = Color(red: 0.17, green: 0.17, blue: 0.18)
}
