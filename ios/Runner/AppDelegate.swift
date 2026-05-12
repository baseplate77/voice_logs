import Flutter
import UIKit
import AVFoundation
import ActivityKit
import BackgroundTasks

@main
@objc class AppDelegate: FlutterAppDelegate {

  private let processingTaskIdentifier = "com.nj.voxsynth.synthesis"

  private var intentChannel: FlutterMethodChannel?
  private var intentChannelReady = false
  private var pendingIntentActions: [String] = []
  private var isRecordingForNativeControls = false

  private var backgroundTaskChannel: FlutterMethodChannel?
  private var backgroundTaskChannelReady = false
  private var pendingProcessingTask = false
  private var activeProcessingTask: BGProcessingTask?
  private var activeUiBackgroundTasks = Set<Int>()

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    registerProcessingTask()

    // Allow the Control Widget's `VoxSynthStartLiveActivityIntent` (compiled
    // into the widget extension target, where AppDelegate / UIApplication
    // are not reachable) to dispatch actions into the running main-app
    // process via a plain Swift bridge.
    if #available(iOS 18.0, *) {
      IntentActionBridge.handler = { [weak self] action in
        self?.dispatchIntentAction(action)
      }
    }

    // Observe Live Activity lifecycle so the main app reacts immediately
    // when the widget extension starts an LA — even if our app is in the
    // foreground (in which case `applicationDidBecomeActive` won't fire).
    if #available(iOS 16.2, *) {
      observeLiveActivityUpdates()
    }

    guard let controller = window?.rootViewController as? FlutterViewController else {
      return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }

    let messenger = controller.binaryMessenger

    // ── Paths channel ──────────────────────────────────────────────────
    let pathsChannel = FlutterMethodChannel(name: "com.nj.voxsynth/paths", binaryMessenger: messenger)
    pathsChannel.setMethodCallHandler { call, result in
      switch call.method {
      case "getApplicationDocumentsPath":
        let path = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first ?? ""
        result(path)
      case "getApplicationSupportPath":
        let path = NSSearchPathForDirectoriesInDomains(.applicationSupportDirectory, .userDomainMask, true).first ?? ""
        result(path)
      case "getTemporaryPath":
        result(NSTemporaryDirectory())
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    // ── Runtime channel ────────────────────────────────────────────────
    let runtimeChannel = FlutterMethodChannel(name: "com.nj.voxsynth/runtime", binaryMessenger: messenger)
    runtimeChannel.setMethodCallHandler { call, result in
      switch call.method {
      case "isIosSimulator":
        #if targetEnvironment(simulator)
        result(true)
        #else
        result(false)
        #endif
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    // ── Audio session channel ──────────────────────────────────────────
    let audioChannel = FlutterMethodChannel(name: "com.nj.voxsynth/audio", binaryMessenger: messenger)
    audioChannel.setMethodCallHandler { call, result in
      switch call.method {
      case "configureAudioSession":
        do {
          let session = AVAudioSession.sharedInstance()
          try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
          try session.setActive(true)
          result(true)
        } catch {
          result(FlutterError(code: "AUDIO_SESSION_ERROR", message: error.localizedDescription, details: nil))
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    // ── Live Activity channel ──────────────────────────────────────────
    let liveActivityChannel = FlutterMethodChannel(name: "com.nj.voxsynth/live_activity", binaryMessenger: messenger)
    liveActivityChannel.setMethodCallHandler { [weak self] call, result in
      self?.handleLiveActivityCall(call: call, result: result)
    }

    // ── Background task channel ──────────────────────────────────────
    let bgTaskChannel = FlutterMethodChannel(name: "com.nj.voxsynth/background_task", binaryMessenger: messenger)
    self.backgroundTaskChannel = bgTaskChannel
    bgTaskChannel.setMethodCallHandler { [weak self, weak application] call, result in
      guard let self = self, let application = application else {
        result(FlutterError(code: "UNAVAILABLE", message: "Application delegate unavailable", details: nil))
        return
      }
      self.handleBackgroundTaskCall(application: application, call: call, result: result)
    }

    // ── Intents channel ────────────────────────────────────────────────
    let iChannel = FlutterMethodChannel(name: "com.nj.voxsynth/intents", binaryMessenger: messenger)
    self.intentChannel = iChannel
    iChannel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(FlutterError(code: "UNAVAILABLE", message: "Application delegate unavailable", details: nil))
        return
      }
      switch call.method {
      case "getPendingActions":
        self.intentChannelReady = true
        var actions = self.pendingIntentActions + PendingIntentStore.consumeAll()
        self.pendingIntentActions.removeAll()
        // Sync with any Live Activity that's already in "recording" phase
        // but isn't reflected on the Flutter side. This catches the case
        // where the Control Widget's intent ran in the widget extension
        // process and never dispatched to the main app via the in-process
        // bridge, so nothing got queued.
        if #available(iOS 16.2, *), self.shouldDispatchStartFromActiveLiveActivity() {
          if !actions.contains("start") {
            actions.append("start")
          }
        }
        result(actions)
      case "getPendingAction":
        self.intentChannelReady = true
        if self.pendingIntentActions.isEmpty {
          self.pendingIntentActions.append(contentsOf: PendingIntentStore.consumeAll())
        }
        var action: String? = self.pendingIntentActions.isEmpty ? nil : self.pendingIntentActions.removeFirst()
        if action == nil, #available(iOS 16.2, *),
           self.shouldDispatchStartFromActiveLiveActivity() {
          action = "start"
        }
        result(action)
      case "reportRecordingState":
        self.isRecordingForNativeControls = call.arguments as? Bool ?? false
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  // ── Lifecycle: sync Flutter recording state with the Live Activity ──
  override func applicationDidBecomeActive(_ application: UIApplication) {
    super.applicationDidBecomeActive(application)
    if #available(iOS 16.2, *) {
      syncRecordingStateWithLiveActivity()
    }
  }

  /// Cover the case where the Control Widget's `LiveActivityStartingIntent`
  /// ran inside the widget extension process: the Live Activity is showing
  /// "recording" but `IntentActionBridge.handler` was never fired in the
  /// main app, so Flutter never received a "start" action and the home
  /// screen stays Idle. Dispatching a "start" here brings the two back
  /// into sync. Safe to call repeatedly — the Flutter listener treats
  /// "start" idempotently when state is already Active.
  @available(iOS 16.2, *)
  private func syncRecordingStateWithLiveActivity() {
    guard shouldDispatchStartFromActiveLiveActivity() else { return }
    dispatchIntentAction("start")
  }

  /// True when a Live Activity is in the "recording" phase but the Flutter
  /// recording controller hasn't reported itself as active. Means the LA was
  /// started by something outside the main app's normal lifecycle (typically
  /// the Control Widget's intent running in the widget extension process)
  /// and Flutter still has to be told to begin actually capturing audio.
  @available(iOS 16.2, *)
  private func shouldDispatchStartFromActiveLiveActivity() -> Bool {
    if isRecordingForNativeControls { return false }
    return Activity<VoxSynthAttributes>.activities.contains { activity in
      activity.content.state.phase == "recording"
    }
  }

  /// Subscribes to ActivityKit's activity-list updates so we hear about
  /// Live Activities started by the widget extension process immediately,
  /// not only when the app next becomes active. Without this, a Control
  /// Widget press while our app is in the foreground would leave the home
  /// screen out of sync until the user backgrounds and re-foregrounds.
  @available(iOS 16.2, *)
  private func observeLiveActivityUpdates() {
    Task { [weak self] in
      for await _ in Activity<VoxSynthAttributes>.activityUpdates {
        guard let self else { return }
        await MainActor.run {
          self.syncRecordingStateWithLiveActivity()
        }
      }
    }
  }

  // ── URL scheme handler (voxsynth://start, voxsynth://stop, voxsynth://log/<id>) ─────────
  override func application(
    _ app: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any] = [:]
  ) -> Bool {
    if url.scheme == "voxsynth" {
      dispatchIntentAction(actionFromURL(url))
      return true
    }
    return super.application(app, open: url, options: options)
  }

  private func actionFromURL(_ url: URL) -> String {
    let host = url.host ?? ""
    if host == "log" {
      let logId = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
      if !logId.isEmpty {
        return "openLog:\(logId)"
      }
    }

    if host == "open",
       let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
       let logId = components.queryItems?.first(where: { $0.name == "logId" })?.value,
       !logId.isEmpty {
      return "openLog:\(logId)"
    }

    return host.isEmpty ? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) : host
  }

  // ── Intent dispatch (called by AppIntents) ─────────────────────────
  func dispatchIntentAction(_ action: String) {
    DispatchQueue.main.async { [weak self] in
      guard let self = self, !action.isEmpty else { return }

      // Toggle: if "start" arrives while already recording, stop instead.
      let resolved = (action == "start" && self.isRecordingForNativeControls) ? "stop" : action

      // Start the Live Activity immediately from native so it appears on the
      // lock screen before Flutter is ready.
      if resolved == "start" {
        self.startLiveActivityFromIntent()
      }

      if self.intentChannelReady, let channel = self.intentChannel {
        channel.invokeMethod("onIntentAction", arguments: resolved)
      } else {
        self.pendingIntentActions.append(resolved)
      }
    }
  }

  /// Start a Live Activity from a non-intent context (URL handler, etc).
  /// Bails out if the StartRecordingIntent already kicked one off — calling
  /// Activity.request() from here while the app is in the background fails
  /// with "Target is not foreground", and there's no point recreating it.
  private func startLiveActivityFromIntent() {
    guard #available(iOS 16.2, *) else { return }
    guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
    if !Activity<VoxSynthAttributes>.activities.isEmpty { return }

    let now = Date()
    let state = VoxSynthAttributes.ContentState(
      elapsedSeconds: 0,
      startedAtMillis: Int64(now.timeIntervalSince1970 * 1000),
      phase: "recording",
      isTranscribing: false,
      waveformLevels: []
    )

    Task {
      do {
        let content = ActivityContent(state: state, staleDate: nil)
        let _ = try Activity.request(attributes: VoxSynthAttributes(), content: content)
      } catch {
        // Foreground-required guarantee — leave the existing native LA alone.
      }
    }
  }

  // ── BGTaskScheduler handling ───────────────────────────────────────
  private func registerProcessingTask() {
    BGTaskScheduler.shared.register(forTaskWithIdentifier: processingTaskIdentifier, using: nil) { [weak self] task in
      guard let self = self, let processingTask = task as? BGProcessingTask else {
        task.setTaskCompleted(success: false)
        return
      }
      self.handleProcessingTask(processingTask)
    }
  }

  private func handleProcessingTask(_ task: BGProcessingTask) {
    DispatchQueue.main.async { [weak self] in
      guard let self = self else {
        task.setTaskCompleted(success: false)
        return
      }
      self.activeProcessingTask = task
      task.expirationHandler = { [weak self] in
        DispatchQueue.main.async {
          self?.backgroundTaskChannel?.invokeMethod("onBackgroundProcessingTaskExpired", arguments: nil)
          self?.activeProcessingTask?.setTaskCompleted(success: false)
          self?.activeProcessingTask = nil
        }
      }
      self.dispatchProcessingTaskEvent()
    }
  }

  private func dispatchProcessingTaskEvent() {
    if backgroundTaskChannelReady, let channel = backgroundTaskChannel {
      channel.invokeMethod("onBackgroundProcessingTask", arguments: nil)
    } else {
      pendingProcessingTask = true
    }
  }

  private func handleBackgroundTaskCall(
    application: UIApplication,
    call: FlutterMethodCall,
    result: @escaping FlutterResult
  ) {
    switch call.method {
    case "beginBackgroundTask":
      var taskId = UIBackgroundTaskIdentifier.invalid
      taskId = application.beginBackgroundTask { [weak self, weak application] in
        DispatchQueue.main.async {
          let rawId = Int(taskId.rawValue)
          if self?.activeUiBackgroundTasks.remove(rawId) != nil {
            application?.endBackgroundTask(taskId)
          }
        }
      }
      let rawId = Int(taskId.rawValue)
      if taskId != .invalid {
        activeUiBackgroundTasks.insert(rawId)
      }
      result(rawId)
    case "endBackgroundTask":
      let args = call.arguments as? [String: Any] ?? [:]
      if let rawId = args["taskId"] as? Int {
        let taskId = UIBackgroundTaskIdentifier(rawValue: rawId)
        if activeUiBackgroundTasks.remove(rawId) != nil {
          application.endBackgroundTask(taskId)
        }
      }
      result(nil)
    case "scheduleProcessingTask":
      scheduleProcessingTask(call: call, result: result)
    case "cancelProcessingTask":
      BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: processingTaskIdentifier)
      result(nil)
    case "completeProcessingTask":
      let args = call.arguments as? [String: Any] ?? [:]
      let success = args["success"] as? Bool ?? true
      activeProcessingTask?.setTaskCompleted(success: success)
      activeProcessingTask = nil
      result(nil)
    case "getPendingProcessingTask":
      backgroundTaskChannelReady = true
      let pending = pendingProcessingTask
      pendingProcessingTask = false
      result(pending)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func scheduleProcessingTask(call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    let earliestBeginSeconds = args["earliestBeginSeconds"] as? Double ?? 60
    let request = BGProcessingTaskRequest(identifier: processingTaskIdentifier)
    request.requiresNetworkConnectivity = false
    request.requiresExternalPower = false
    if earliestBeginSeconds > 0 {
      request.earliestBeginDate = Date(timeIntervalSinceNow: earliestBeginSeconds)
    }

    do {
      try BGTaskScheduler.shared.submit(request)
      result(true)
    } catch {
      result(FlutterError(code: "BG_TASK_SCHEDULE_FAILED", message: error.localizedDescription, details: nil))
    }
  }

  // ── Live Activity handling ─────────────────────────────────────────
  private func handleLiveActivityCall(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard #available(iOS 16.2, *) else {
      result(FlutterError(code: "UNSUPPORTED", message: "Live Activities require iOS 16.2+", details: nil))
      return
    }

    switch call.method {
    case "startActivity":
      startLiveActivity(call: call, result: result)
    case "updateActivity":
      updateLiveActivity(call: call, result: result)
    case "refineActivity":
      refineLiveActivity(call: call, result: result)
    case "completeActivity":
      completeLiveActivity(call: call, result: result)
    case "endActivity":
      endLiveActivity(result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  @available(iOS 16.2, *)
  private func startLiveActivity(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard ActivityAuthorizationInfo().areActivitiesEnabled else {
      result(FlutterError(code: "DISABLED", message: "Live Activities are disabled by the user", details: nil))
      return
    }

    let args = call.arguments as? [String: Any] ?? [:]
    let elapsed = args["elapsedSeconds"] as? Int ?? 0
    let startedAtMillis = parseInt64(args["startedAtMillis"])
    let phase = parseActivityPhase(args["phase"], fallback: "recording")
    let waveform = parseWaveformLevels(args["waveformLevels"])

    let attributes = VoxSynthAttributes()
    let state = VoxSynthAttributes.ContentState(
      elapsedSeconds: elapsed,
      startedAtMillis: startedAtMillis,
      phase: phase,
      isTranscribing: phase == "transcribing",
      waveformLevels: waveform
    )

    Task {
      // If a Live Activity is already showing (typically started by the
      // AppIntent that brought us up — Activity.request() is allowed inside
      // an intent's perform() but not from a background method-channel call),
      // adopt it by updating instead of tearing it down and re-requesting.
      // Activity.update() is allowed from background; Activity.request() is
      // not — it would fail with "Target is not foreground".
      if let existing = Activity<VoxSynthAttributes>.activities.first {
        let content = ActivityContent(state: state, staleDate: nil)
        await existing.update(content)
        result(true)
        return
      }

      do {
        let content = ActivityContent(state: state, staleDate: nil)
        let _ = try Activity.request(attributes: attributes, content: content)
        result(true)
      } catch {
        result(FlutterError(code: "START_FAILED", message: error.localizedDescription, details: nil))
      }
    }
  }

  @available(iOS 16.2, *)
  private func updateLiveActivity(call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    let elapsed = args["elapsedSeconds"] as? Int ?? 0
    let startedAtMillis = parseInt64(args["startedAtMillis"])
    let transcribing = args["isTranscribing"] as? Bool ?? false
    let phase = parseActivityPhase(args["phase"], fallback: transcribing ? "transcribing" : "recording")
    let waveform = parseWaveformLevels(args["waveformLevels"])

    let state = VoxSynthAttributes.ContentState(
      elapsedSeconds: elapsed,
      startedAtMillis: startedAtMillis,
      phase: phase,
      isTranscribing: phase == "transcribing",
      waveformLevels: waveform
    )
    let content = ActivityContent(state: state, staleDate: nil)

    Task {
      for activity in Activity<VoxSynthAttributes>.activities {
        await activity.update(content)
      }
      result(true)
    }
  }

  @available(iOS 16.2, *)
  private func refineLiveActivity(call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    let elapsed = args["elapsedSeconds"] as? Int ?? 0
    let startedAtMillis = parseInt64(args["startedAtMillis"])
    let waveform = parseWaveformLevels(args["waveformLevels"])
    let logId = args["logId"] as? String

    let state = VoxSynthAttributes.ContentState(
      elapsedSeconds: elapsed,
      startedAtMillis: startedAtMillis,
      phase: "refining",
      isTranscribing: false,
      waveformLevels: waveform,
      logId: logId
    )
    let content = ActivityContent(state: state, staleDate: nil)

    Task {
      for activity in Activity<VoxSynthAttributes>.activities {
        await activity.update(content)
      }
      result(true)
    }
  }

  @available(iOS 16.2, *)
  private func completeLiveActivity(call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    let elapsed = args["elapsedSeconds"] as? Int ?? 0
    let startedAtMillis = parseInt64(args["startedAtMillis"])
    let waveform = parseWaveformLevels(args["waveformLevels"])
    let logId = args["logId"] as? String
    let state = VoxSynthAttributes.ContentState(
      elapsedSeconds: elapsed,
      startedAtMillis: startedAtMillis,
      phase: "completed",
      isTranscribing: false,
      waveformLevels: waveform,
      logId: logId
    )
    let content = ActivityContent(state: state, staleDate: nil)
    let dismissAt = Date(timeIntervalSinceNow: 18)

    Task {
      for activity in Activity<VoxSynthAttributes>.activities {
        await activity.end(content, dismissalPolicy: .after(dismissAt))
      }
      result(true)
    }
  }

  private func parseInt64(_ raw: Any?) -> Int64 {
    if let value = raw as? Int64 { return value }
    if let value = raw as? Int { return Int64(value) }
    if let value = raw as? NSNumber { return value.int64Value }
    return 0
  }

  private func parseActivityPhase(_ raw: Any?, fallback: String) -> String {
    guard let phase = raw as? String else { return fallback }
    switch phase {
    case "recording", "transcribing", "refining", "completed":
      return phase
    default:
      return fallback
    }
  }

  private func parseWaveformLevels(_ raw: Any?) -> [Double] {
    guard let values = raw as? [Any] else { return [] }
    return values.compactMap { value in
      if let double = value as? Double { return min(1.0, max(0.0, double)) }
      if let number = value as? NSNumber { return min(1.0, max(0.0, number.doubleValue)) }
      return nil
    }
  }

  @available(iOS 16.2, *)
  private func endLiveActivity(result: @escaping FlutterResult) {
    Task {
      for activity in Activity<VoxSynthAttributes>.activities {
        await activity.end(nil, dismissalPolicy: .immediate)
      }
      result(true)
    }
  }
}
