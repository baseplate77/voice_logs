import AppIntents

@available(iOS 16.4, *)
struct VoxSynthShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: StartRecordingIntent(),
      phrases: [
        "Start voice log in \(.applicationName)",
        "Record in \(.applicationName)",
        "Start recording with \(.applicationName)",
      ],
      shortTitle: "Start Voice Log",
      systemImageName: "mic.fill"
    )
    AppShortcut(
      intent: StopRecordingIntent(),
      phrases: [
        "Stop voice log in \(.applicationName)",
        "Stop recording in \(.applicationName)",
      ],
      shortTitle: "Stop Voice Log",
      systemImageName: "stop.circle"
    )
  }
}
