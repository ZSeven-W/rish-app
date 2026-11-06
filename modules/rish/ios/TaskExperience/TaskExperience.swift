import UIKit
import UserNotifications
import BackgroundTasks
import ActivityKit

struct TaskPreferences: Codable {
  var completed = false
  var failed = false
  var attention = false
  var liveActivity = false
  var background = false
  var muted: [String] = []
}

@MainActor
final class TaskExperience: NSObject, UNUserNotificationCenterDelegate {
  static let shared = TaskExperience()
  static var prefix: String { (Bundle.main.bundleIdentifier ?? "tech.zseven.rish") + ".task" }
  static let preferenceKey = "rish.task.preferences.v1"
  private var preferences = TaskPreferences()
  private var current: [String: String]?
  private var startedAt = Date()
  private var visibleConversation: String?
  private var language: String?
  private var notified: Set<String> = []
  private var activity: Any?
  private let defaults: UserDefaults
  private let background: TaskBackgroundExecution
  private let foreground: @MainActor () -> Bool
  private var configured = false
  // The GPUI target does not embed a widget extension yet.
  private let liveActivitiesAvailable = false
  private var actions: [[String: String]] = []
  var emit: (([String: String]) -> Void)?

  init(defaults: UserDefaults = .standard, driver: TaskBackgroundDriver? = nil,
       foreground: (@MainActor () -> Bool)? = nil) {
    self.defaults = defaults
    self.foreground = foreground ?? { UIApplication.shared.applicationState == .active }
    background = TaskBackgroundExecution(driver: driver ?? SystemTaskBackgroundDriver(), defaults: defaults)
    super.init()
    background.onCancel = { [weak self] run, reason in self?.requestCancel(runId: run, reason: reason) }
  }
  func configure() {
    guard !configured else { return }
    configured = true
    if let data = defaults.data(forKey: Self.preferenceKey),
       let saved = try? JSONDecoder().decode(TaskPreferences.self, from: data) { preferences = saved }
    UNUserNotificationCenter.current().delegate = self
    background.configure()
  }
  func foregroundChanged(_ active: Bool) {
    if !active { background.enterBackground() }
  }
  func willTerminate() { background.interrupt(reason: "background_expired") }

  private var chinese: Bool { (language ?? Locale.preferredLanguages.first ?? "en").hasPrefix("zh") }
  private func text(_ en: String, _ zh: String) -> String { chinese ? zh : en }
  private func stage(_ phase: String) -> String {
    switch phase {
    case "preparing", "starting": return text("Preparing", "正在准备")
    case "sending": return text("Waiting for model", "等待模型回复")
    case "approval_pending": return text("Needs your attention", "需要你处理")
    case "executing": return text("Running tools", "正在执行工具")
    case "recovering": return text("Checking saved state", "核对已保存状态")
    case "cancelling": return text("Stopping safely", "正在安全停止")
    case "finalizing": return text("Saving result", "正在保存结果")
    case "completed": return text("Task complete", "任务已完成")
    case "cancelled": return text("Task stopped", "任务已停止")
    default: return text("Return to Rish to continue", "返回 Rish 继续处理")
    }
  }

  func handle(_ input: String) async throws -> Any {
    guard input.utf8.count < 32768,
          let data = input.data(using: .utf8),
          let request = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let schema = request["schema_version"] as? NSNumber,
          CFGetTypeID(schema) != CFBooleanGetTypeID(), schema.intValue == 1,
          !CFNumberIsFloatType(schema), let op = request["op"] as? String else { throw invalid() }
    switch op {
    case "inspection":
      guard Bundle.main.bundleIdentifier?.hasPrefix("dev.zseven.rish.taskacceptance") == true else { throw invalid() }
      var activityActive = false
      if #available(iOS 16.2, *), let live = activity as? Activity<RishTaskAttributes> { activityActive = live.activityState == .active }
      return ["visibleConversation": visibleConversation ?? "", "running": current != nil,
        "phase": current?["phase"] ?? "idle", "interrupted": current?["interrupted"] == "true", "stopRequested": current?["stopRequested"] == "true",
        "liveActivityActive": activityActive, "backgroundAccepted": background.accepted, "backgroundAdmission": background.admission,
        "applicationActive": foreground()]
    case "settings": return await settings()
    case "preferences":
      guard let raw = request["preferences"] as? [String: Any] else { throw invalid() }
      let value = try JSONDecoder().decode(TaskPreferences.self, from: JSONSerialization.data(withJSONObject: raw))
      guard value.muted.count <= 500, value.muted.allSatisfy(validID) else { throw invalid() }
      let wasBackgroundEnabled = preferences.background
      preferences = value
      defaults.set(try JSONEncoder().encode(value), forKey: Self.preferenceKey)
      if !value.liveActivity { await endActivity() }
      if wasBackgroundEnabled, !value.background, current != nil { background.interrupt(reason: "background_expired") }
      return await settings()
    case "permission":
      guard strictBool(request["userInitiated"]) == true else { throw invalid() }
      _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
      return await settings()
    case "openSettings":
      if let url = URL(string: UIApplication.openSettingsURLString) { await UIApplication.shared.open(url) }
      return true
    case "visible":
      visibleConversation = request["conversationId"] as? String
      if let locale = request["locale"] as? String, ["zh-CN", "en-US"].contains(locale) { language = locale }
      return true
    case "drain":
      let result = actions.map { action -> [String: Any] in
        var event: [String: Any] = action; event["schema_version"] = 1; return event
      }
      actions.removeAll(); return result
    case "begin":
      guard let run = request["runId"] as? String, validID(run),
            let conversation = request["conversationId"] as? String, validID(conversation) else { throw invalid() }
      if current?["runId"] == run {
        guard current?["conversationId"] == conversation else { throw invalid() }
        return beginResult()
      }
      guard current == nil, let eligible = strictBool(request["backgroundEligible"]) else { throw invalid() }
      current = ["runId": run, "conversationId": conversation, "phase": "preparing"]
      startedAt = Date(); notified.removeAll()
      background.begin(runId: run, eligible: eligible, enabled: preferences.background,
        foreground: foreground(), subtitle: stage("preparing"))
      // ActivityKit authorization alone cannot establish extension availability.
      // Continue to report false until a Widget is actually embedded.
      if !foreground() { background.enterBackground() }
      return beginResult()
    case "update":
      guard let phase = request["phase"] as? String,
            ["preparing", "persistence_pending", "starting", "sending", "approval_pending", "executing", "recovering", "cancelling", "finalizing", "retryable", "resume_available", "commit_pending", "blocked"].contains(phase) else { throw invalid() }
      guard current?["runId"] == request["runId"] as? String, current != nil else { return false }
      if current?["stopRequested"] == "true",
         !["cancelling", "finalizing", "commit_pending", "persistence_pending"].contains(phase) { return false }
      if phase != "approval_pending" { notified.remove("attention") }
      current?["phase"] = phase
      background.update(stage: stage(phase))
      if #available(iOS 16.2, *), let live = activity as? Activity<RishTaskAttributes> {
        await live.update(ActivityContent(state: .init(stage: stage(phase), finished: false), staleDate: Date().addingTimeInterval(90)))
      }
      if phase == "approval_pending" { await notify("attention") }
      return true
    case "end":
      guard current?["runId"] == request["runId"] as? String, current != nil else { return false }
      let status = request["status"] as? String ?? "blocked"
      // The actor calls end only after its terminal checkpoint is durable.
      // Release the saving lease before awaiting best-effort display delivery.
      background.end(success: status == "completed")
      if status == "completed" { await notify("completed") }
      else if status != "cancelled" || current?["interrupted"] == "true" { await notify("failed") }
      await endActivity()
      current = nil
      return true
    default: throw invalid()
    }
  }

  private func strictBool(_ value: Any?) -> Bool? {
    guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
    return number.boolValue
  }
  private func validID(_ value: String) -> Bool { !value.isEmpty && value.utf8.count <= 256 && !value.contains("\0") }
  private func invalid() -> NSError { NSError(domain: "RishTaskExperience", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid task request"]) }
  private func settings() async -> [String: Any] {
    let status = await UNUserNotificationCenter.current().notificationSettings()
    let authorization: String
    switch status.authorizationStatus {
    case .authorized, .provisional, .ephemeral: authorization = "authorized"
    case .denied: authorization = "denied"
    default: authorization = "notDetermined"
    }
    return ["schema_version": 1, "available": true, "foreground": foreground(),
            "notifications": authorization, "liveActivitiesAvailable": liveActivitiesAvailable,
            "backgroundAvailable": background.available, "backgroundAdmission": background.admission,
            "backgroundAccepted": background.accepted,
            "preferences": (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(preferences))) ?? [:]]
  }

  private func notify(_ kind: String) async {
    guard let current else { return }
    let settings = await UNUserNotificationCenter.current().notificationSettings()
    let enabled = kind == "completed" ? preferences.completed : kind == "failed" ? preferences.failed : preferences.attention
    guard TaskAlertPolicy.allows(kind: kind, enabled: enabled,
      muted: preferences.muted.contains(current["conversationId"]!),
      foreground: foreground(),
      viewingConversation: visibleConversation == current["conversationId"],
      delivered: notified.contains(kind), sameRun: self.current?["runId"] == current["runId"]),
      [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus) else { return }
    let content = UNMutableNotificationContent()
    content.title = "Rish"
    content.body = kind == "completed" ? stage("completed") : kind == "attention" ? stage("approval_pending") : text("Task needs review", "任务需要检查")
    content.sound = .default
    content.threadIdentifier = current["conversationId"]!
    content.userInfo = ["conversationId": current["conversationId"]!, "runId": current["runId"]!]
    do {
      try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: current["runId"]! + "." + kind, content: content, trigger: nil))
      notified.insert(kind)
    } catch { /* Display delivery must not change durable task outcome. */ }
  }

  private func beginResult() -> [String: Any] {
    ["schema_version": 1, "started": true, "backgroundAdmission": background.admission,
     "backgroundAccepted": background.accepted]
  }
  private func endActivity() async {
    let previous = activity
    activity = nil
    if #available(iOS 16.2, *), let live = previous as? Activity<RishTaskAttributes> { await live.end(nil, dismissalPolicy: .immediate) }
  }
  func cancelFromActivity(runId: String, conversationId: String) {
    guard current?["conversationId"] == conversationId, current?["runId"] == runId else { return }
    background.interrupt(reason: "user_stop")
  }
  private func requestCancel(runId: String, reason: String) {
    guard current?["runId"] == runId else { return }
    current?["interrupted"] = reason == "user_stop" ? "false" : "true"
    current?["stopRequested"] = "true"
    guard let current else { return }
    queue(["action": "cancel", "conversationId": current["conversationId"]!, "runId": current["runId"]!, "reason": reason])
    Task {
      guard self.current?["runId"] == runId else { return }
      await endActivity()
    }
  }
  private func queue(_ action: [String: String]) {
    if !actions.contains(action) { actions.append(action); actions = Array(actions.suffix(32)) }
    emit?(action)
  }
  func open(_ url: URL) -> Bool {
    guard url.scheme == "rish", url.host == "task", let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
          let conversation = parts.queryItems?.first(where: { $0.name == "conversation" })?.value, validID(conversation),
          let run = parts.queryItems?.first(where: { $0.name == "run" })?.value, validID(run) else { return false }
    queue(["action": "open", "conversationId": conversation, "runId": run]); return true
  }
  nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
    await MainActor.run {
      let conversation = notification.request.content.userInfo["conversationId"] as? String
      return conversation == self.visibleConversation ? [] : [.banner, .sound]
    }
  }
  nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
    guard let conversation = response.notification.request.content.userInfo["conversationId"] as? String,
          let run = response.notification.request.content.userInfo["runId"] as? String else { return }
    await MainActor.run { self.queue(["action": "open", "conversationId": conversation, "runId": run]) }
  }
}
