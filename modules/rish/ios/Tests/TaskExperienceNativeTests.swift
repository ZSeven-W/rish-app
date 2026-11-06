import XCTest
import UIKit
import UserNotifications
@testable import RishGPUI

@MainActor
private final class TestContinuedHandle: TaskContinuedHandle {
  let identifier: String
  var expiration: (() -> Void)?
  var finishes: [Bool] = []
  var progress: [Int64] = []
  init(_ identifier: String) { self.identifier = identifier }
  func update(stage: String, transitions: Int64) { progress.append(transitions) }
  func finish(success: Bool) { finishes.append(success) }
}

@MainActor
private final class TestBackgroundDriver: TaskBackgroundDriver {
  var available = true
  var registrationAccepted = true
  var submissionFails = false
  var submitted: [String] = []
  var cancelled: [String] = []
  var handlers: [String: (TaskContinuedHandle) -> Void] = [:]
  var checkpointExpiration: (() -> Void)?
  var checkpoints = 0
  var endedCheckpoints = 0
  func register(identifier: String, handler: @escaping (TaskContinuedHandle) -> Void) -> Bool {
    if registrationAccepted { handlers[identifier] = handler }
    return registrationAccepted
  }
  func submit(identifier: String, subtitle: String) throws {
    if submissionFails { throw NSError(domain: "test", code: 1) }
    submitted.append(identifier)
  }
  func cancel(identifier: String) { cancelled.append(identifier) }
  func beginCheckpoint(expiration: @escaping () -> Void) -> UIBackgroundTaskIdentifier {
    checkpoints += 1
    checkpointExpiration = expiration
    return UIBackgroundTaskIdentifier(rawValue: 7)
  }
  func endCheckpoint(_ identifier: UIBackgroundTaskIdentifier) { endedCheckpoints += 1 }
  func acceptLast() -> TestContinuedHandle {
    let handle = TestContinuedHandle(submitted.last!)
    handlers[handle.identifier]!(handle)
    return handle
  }
}

@MainActor
final class TaskExperienceNativeTests: XCTestCase {
  private func fixture() -> (TaskBackgroundExecution, TestBackgroundDriver, UserDefaults) {
    let driver = TestBackgroundDriver()
    let suite = "rish-task-test-" + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
    return (TaskBackgroundExecution(driver: driver, defaults: defaults), driver, defaults)
  }
  func testDisabledAndAutomaticRunsCannotRequestContinuedProcessing() {
    let (execution, driver, _) = fixture()
    execution.begin(runId: "manual", eligible: true, enabled: false, foreground: true, subtitle: "Preparing")
    XCTAssertEqual(execution.admission, "disabled")
    execution.end(success: true)
    execution.begin(runId: "due", eligible: false, enabled: true, foreground: true, subtitle: "Preparing")
    XCTAssertEqual(execution.admission, "notEligible")
    execution.end(success: true)
    execution.begin(runId: "background", eligible: true, enabled: true, foreground: false, subtitle: "Preparing")
    XCTAssertEqual(execution.admission, "notEligible")
    XCTAssertTrue(driver.handlers.isEmpty)
    XCTAssertTrue(driver.submitted.isEmpty)
    execution.end(success: false)
  }
  func testSubmissionFailureAndPendingAdmissionCancelImmediatelyOnBackground() {
    let (execution, driver, _) = fixture()
    driver.submissionFails = true
    execution.begin(runId: "failed", eligible: true, enabled: true, foreground: true, subtitle: "Preparing")
    XCTAssertEqual(execution.admission, "unavailable")
    execution.end(success: false)
    driver.submissionFails = false
    execution.begin(runId: "pending", eligible: true, enabled: true, foreground: true, subtitle: "Preparing")
    XCTAssertEqual(execution.admission, "submitted")
    XCTAssertFalse(execution.accepted)
    var events: [String] = []
    execution.onCancel = { run, reason in events.append(run + ":" + reason) }
    execution.enterBackground()
    XCTAssertEqual(events, ["pending:background_expired"])
    XCTAssertEqual(driver.checkpoints, 1)
    XCTAssertEqual(driver.endedCheckpoints, 0)
    let late = driver.acceptLast()
    XCTAssertFalse(execution.accepted)
    XCTAssertTrue(late.finishes.isEmpty)
    execution.end(success: false)
    XCTAssertEqual(late.finishes, [false])
    XCTAssertEqual(driver.endedCheckpoints, 1)
  }
  func testSystemExpirationWaitsForDurableEndBeforeReleasingCheckpoint() {
    let (execution, driver, _) = fixture()
    execution.begin(runId: "run", eligible: true, enabled: true, foreground: true, subtitle: "Preparing")
    let handle = driver.acceptLast()
    XCTAssertTrue(execution.accepted)
    execution.enterBackground()
    XCTAssertEqual(driver.checkpoints, 0)
    var events: [String] = []
    execution.onCancel = { _, reason in events.append(reason) }
    handle.expiration?()
    XCTAssertEqual(events, ["background_expired"])
    XCTAssertFalse(execution.accepted)
    XCTAssertTrue(handle.finishes.isEmpty)
    XCTAssertEqual(driver.endedCheckpoints, 0)
    execution.update(stage: "Saving result")
    execution.update(stage: "Saving result")
    XCTAssertEqual(handle.progress, [0, 1, 1])
    execution.end(success: false)
    XCTAssertEqual(handle.finishes, [false])
    XCTAssertEqual(driver.endedCheckpoints, 1)
  }
  func testOSCheckpointDeadlineIsReleasedWithoutClaimingSuccessfulPersistence() {
    let (execution, driver, _) = fixture()
    execution.begin(runId: "run", eligible: true, enabled: true, foreground: true, subtitle: "Preparing")
    let handle = driver.acceptLast()
    handle.expiration?()
    driver.checkpointExpiration?()
    XCTAssertEqual(execution.admission, "expired")
    execution.enterBackground()
    XCTAssertEqual(driver.checkpoints, 1, "an expired cleanup lease cannot be renewed")
    XCTAssertEqual(handle.finishes, [false])
    XCTAssertEqual(driver.endedCheckpoints, 1)
    execution.end(success: false)
    XCTAssertEqual(driver.endedCheckpoints, 1)
  }
  func testStaleCheckpointCallbackCannotCancelResumedRun() {
    let (execution, driver, _) = fixture()
    execution.begin(runId: "run", eligible: false, enabled: false, foreground: true, subtitle: "Preparing")
    execution.enterBackground()
    let stale = driver.checkpointExpiration
    execution.end(success: false)
    execution.begin(runId: "run", eligible: true, enabled: true, foreground: true, subtitle: "Preparing")
    let resumed = driver.acceptLast()
    stale?()
    XCTAssertTrue(execution.accepted)
    XCTAssertTrue(resumed.finishes.isEmpty)
    XCTAssertEqual(driver.endedCheckpoints, 1)
    execution.end(success: true)
  }
  func testLateHandlerCannotRecreateEndedRun() {
    let (execution, driver, _) = fixture()
    execution.begin(runId: "run", eligible: true, enabled: true, foreground: true, subtitle: "Preparing")
    execution.end(success: true)
    let handle = driver.acceptLast()
    XCTAssertEqual(handle.finishes, [true])
    XCTAssertFalse(execution.accepted)
    XCTAssertEqual(execution.admission, "finished")
  }
  func testDisablingBackgroundRevokesPendingAdmissionBeforeLateHandler() async throws {
    let (_, driver, defaults) = fixture()
    let oldDelegate = UNUserNotificationCenter.current().delegate
    defer { UNUserNotificationCenter.current().delegate = oldDelegate }
    var preferences = TaskPreferences(); preferences.background = true
    defaults.set(try JSONEncoder().encode(preferences), forKey: TaskExperience.preferenceKey)
    let service = TaskExperience(defaults: defaults, driver: driver, foreground: { true })
    service.configure()
    func call(_ op: String, _ fields: [String: Any]) async throws -> Any {
      var request = fields; request["schema_version"] = 1; request["op"] = op
      return try await service.handle(String(data: JSONSerialization.data(withJSONObject: request), encoding: .utf8)!)
    }
    _ = try await call("begin", ["runId": "run", "conversationId": "conversation", "backgroundEligible": true])
    preferences.background = false
    let raw = try JSONSerialization.jsonObject(with: JSONEncoder().encode(preferences))
    _ = try await call("preferences", ["preferences": raw])
    let late = driver.acceptLast()
    XCTAssertTrue(late.finishes.isEmpty)
    let events = try await call("drain", [:]) as! [[String: Any]]
    XCTAssertEqual(events.first?["reason"] as? String, "background_expired")
    _ = try await call("end", ["runId": "run", "status": "cancelled"])
    XCTAssertEqual(late.finishes, [false])
  }
  func testServiceDefaultsPermissionGateAndTypedActionDrain() async throws {
    let (_, driver, defaults) = fixture()
    let oldDelegate = UNUserNotificationCenter.current().delegate
    defer { UNUserNotificationCenter.current().delegate = oldDelegate }
    let service = TaskExperience(defaults: defaults, driver: driver, foreground: { true })
    service.configure()
    func call(_ op: String, _ fields: [String: Any] = [:]) async throws -> Any {
      var request = fields; request["schema_version"] = 1; request["op"] = op
      let bytes = try JSONSerialization.data(withJSONObject: request)
      return try await service.handle(String(data: bytes, encoding: .utf8)!)
    }
    let settings = try await call("settings") as! [String: Any]
    XCTAssertEqual(settings["liveActivitiesAvailable"] as? Bool, false)
    XCTAssertEqual(settings["foreground"] as? Bool, true)
    let preferences = settings["preferences"] as! [String: Any]
    for key in ["completed", "failed", "attention", "background"] { XCTAssertEqual(preferences[key] as? Bool, false) }
    do { _ = try await call("permission"); XCTFail("permission requires an explicit user action") } catch {}
    let began = try await call("begin", ["runId": "run", "conversationId": "conversation", "backgroundEligible": false]) as! [String: Any]
    XCTAssertEqual(began["backgroundAdmission"] as? String, "disabled")
    do { _ = try await call("begin", ["runId": "other", "conversationId": "conversation", "backgroundEligible": true]); XCTFail("cannot replace an uncheckpointed run") } catch {}
    var emitted: [[String: String]] = []
    service.emit = { emitted.append($0) }
    service.cancelFromActivity(runId: "foreign", conversationId: "conversation")
    XCTAssertTrue(emitted.isEmpty)
    service.cancelFromActivity(runId: "run", conversationId: "conversation")
    XCTAssertEqual(emitted.first?["reason"], "user_stop")
    XCTAssertEqual(driver.endedCheckpoints, 0)
    let lateUpdate = try await call("update", ["runId": "run", "phase": "executing"])
    XCTAssertEqual(lateUpdate as? Bool, false)
    let events = try await call("drain") as! [[String: Any]]
    XCTAssertEqual(events.first?["schema_version"] as? Int, 1)
    XCTAssertEqual(events.first?["action"] as? String, "cancel")
    _ = try await call("end", ["runId": "run", "status": "cancelled"])
    XCTAssertEqual(driver.endedCheckpoints, 1)
    XCTAssertTrue(driver.submitted.isEmpty)
  }
}
