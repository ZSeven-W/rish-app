import Foundation
import UIKit
import CryptoKit
import UserNotifications

// Explicit acceptance build only. Never runs in the product's bundle identity,
// never reads credentials, and uses a bounded synthetic file/hash workload.
@MainActor
enum TaskExperienceAcceptance {
  static func startIfRequested() {
    guard Bundle.main.bundleIdentifier?.hasPrefix("dev.zseven.rish.taskacceptance") == true,
          let index = ProcessInfo.processInfo.arguments.firstIndex(of: "-RishTaskAcceptance"),
          ProcessInfo.processInfo.arguments.indices.contains(index + 1) else { return }
    let mode = ProcessInfo.processInfo.arguments[index + 1]
    Task {
      func call(_ op: String, _ payload: [String: Any] = [:]) async throws -> Any {
        var request = payload; request["op"] = op; request["schema_version"] = 1
        let data = try JSONSerialization.data(withJSONObject: request)
        return try await TaskExperience.shared.handle(String(decoding: data, as: UTF8.self))
      }
      let run = "acceptance-" + UUID().uuidString
      let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
      var records: [[String: Any]] = []
      func record(_ phase: String, _ details: [String: Any] = [:]) {
        records.append(["stage": phase, "at": ISO8601DateFormatter().string(from: Date()), "details": details])
        if let data = try? JSONSerialization.data(withJSONObject: ["schema_version": 1, "execution": "synthetic-task-system-acceptance", "run_id": run, "records": records], options: [.prettyPrinted, .sortedKeys]) {
          try? data.write(to: directory.appendingPathComponent("task-experience-acceptance.json"), options: .atomic)
          try? data.write(to: directory.appendingPathComponent(run + ".json"), options: .atomic)
        }
      }
      do {
        let original = try await call("settings") as! [String: Any]
        record("started", ["mode": mode, "settings": original])
        let originalPreferences = original["preferences"] as! [String: Any]
        var testPreferences = originalPreferences
        testPreferences["completed"] = true; testPreferences["failed"] = true
        testPreferences["attention"] = true; testPreferences["background"] = mode == "background"
        testPreferences["liveActivity"] = true
        _ = try await call("preferences", ["preferences": testPreferences])
        if mode == "notify" { _ = try await call("permission", ["userInitiated": true]) }
        try await Task.sleep(nanoseconds: 5_000_000_000)
        let inspection = try await call("inspection") as! [String: Any]
        let conversation = inspection["visibleConversation"] as? String ?? "acceptance-conversation"
        _ = try await call("begin", ["runId": run, "conversationId": conversation, "backgroundEligible": true])
        record("task-started", try await call("inspection") as! [String: Any])
        var interrupted = false
        for step in 0..<45 {
          let bytes = Data(repeating: UInt8(step), count: 16 * 1024)
          let file = directory.appendingPathComponent("task-experience-acceptance.tmp")
          try bytes.write(to: file, options: .atomic)
          let read = try Data(contentsOf: file)
          guard SHA256.hash(data: bytes) == SHA256.hash(data: read) else { throw NSError(domain: "QA", code: 1) }
          try FileManager.default.removeItem(at: file)
          if mode == "cancel", #available(iOS 17.0, *) {
            if step == 5 {
              _ = try await RishCancelTaskIntent(runId: "stale-" + run, conversationId: conversation).perform()
              let stale = try await call("inspection") as! [String: Any]
              guard stale["stopRequested"] as? Bool == false else { throw NSError(domain: "QA stale cancellation", code: 2) }
              record("stale-intent-ignored")
            }
            if step == 10 { _ = try await RishCancelTaskIntent(runId: run, conversationId: conversation).perform() }
          }
          let snapshot = try await call("inspection") as! [String: Any]
          if snapshot["stopRequested"] as? Bool == true { interrupted = true; break }
          _ = try await call("update", ["runId": run, "phase": mode == "notify" && step == 25 ? "approval_pending" : "executing"])
          if step % 10 == 0 { record("work-verified", ["step": step, "runtime": snapshot]) }
          try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        _ = try await call("end", ["runId": run, "status": interrupted ? "cancelled" : "completed"])
        let delivered = await UNUserNotificationCenter.current().deliveredNotifications()
        record("finished", ["interrupted": interrupted, "delivered": delivered.filter { $0.request.identifier.hasPrefix(run) }.map { $0.request.identifier }])
        _ = try await call("preferences", ["preferences": originalPreferences])
      } catch { record("failed", ["error": String(describing: error)]) }
    }
  }
}
