import UIKit
import BackgroundTasks

@MainActor
protocol TaskContinuedHandle: AnyObject {
  var identifier: String { get }
  var expiration: (() -> Void)? { get set }
  func update(stage: String, transitions: Int64)
  func finish(success: Bool)
}

@MainActor
protocol TaskBackgroundDriver: AnyObject {
  var available: Bool { get }
  func register(identifier: String, handler: @escaping (TaskContinuedHandle) -> Void) -> Bool
  func submit(identifier: String, subtitle: String) throws
  func cancel(identifier: String)
  func beginCheckpoint(expiration: @escaping () -> Void) -> UIBackgroundTaskIdentifier
  func endCheckpoint(_ identifier: UIBackgroundTaskIdentifier)
}

@available(iOS 26.0, *)
@MainActor
private final class SystemContinuedHandle: TaskContinuedHandle {
  private let task: BGContinuedProcessingTask
  var identifier: String { task.identifier }
  var expiration: (() -> Void)? {
    didSet { task.expirationHandler = { [weak self] in Task { @MainActor in self?.expiration?() } } }
  }
  init(_ task: BGContinuedProcessingTask) { self.task = task }
  func update(stage: String, transitions: Int64) {
    // The agent has no known total. Only real phase transitions advance work.
    task.progress.totalUnitCount = -1
    task.progress.completedUnitCount = transitions
    task.updateTitle("Rish", subtitle: stage)
  }
  func finish(success: Bool) { task.setTaskCompleted(success: success) }
}

@MainActor
final class SystemTaskBackgroundDriver: TaskBackgroundDriver {
  private var registrations = 0
  var available: Bool {
    if #available(iOS 26.0, *) { return registrations < 256 }
    return false
  }
  func register(identifier: String, handler: @escaping (TaskContinuedHandle) -> Void) -> Bool {
    guard available else { return false }
    if #available(iOS 26.0, *) {
      registrations += 1
      return BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { task in
        Task { @MainActor in
          guard let task = task as? BGContinuedProcessingTask else { task.setTaskCompleted(success: false); return }
          handler(SystemContinuedHandle(task))
        }
      }
    }
    return false
  }
  func submit(identifier: String, subtitle: String) throws {
    if #available(iOS 26.0, *) {
      let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: "Rish", subtitle: subtitle)
      request.strategy = .fail
      try BGTaskScheduler.shared.submit(request)
    } else { throw NSError(domain: "RishTaskExperience", code: 2) }
  }
  func cancel(identifier: String) { BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier) }
  func beginCheckpoint(expiration: @escaping () -> Void) -> UIBackgroundTaskIdentifier {
    UIApplication.shared.beginBackgroundTask(withName: "Rish durable checkpoint") {
      Task { @MainActor in expiration() }
    }
  }
  func endCheckpoint(_ identifier: UIBackgroundTaskIdentifier) { UIApplication.shared.endBackgroundTask(identifier) }
}

// Owns OS admission only. It never resumes an agent or declares a durable run
// complete. The process actor acknowledges persistence with TaskExperience.end.
@MainActor
final class TaskBackgroundExecution {
  private let driver: TaskBackgroundDriver
  private let defaults: UserDefaults
  private var currentRun: String?
  private var generation = UUID()
  private var identifier: String?
  private var handle: TaskContinuedHandle?
  private var checkpoint: UIBackgroundTaskIdentifier = .invalid
  private var checkpointRequested = false
  private var stopped = false
  private var transitions: Int64 = 0
  private var lastStage = ""
  private var finished: [String: Bool] = [:]
  private var finishedOrder: [String] = []
  private(set) var admission = "notRequested"
  var onCancel: ((String, String) -> Void)?
  var available: Bool { driver.available }
  var accepted: Bool { handle != nil && !stopped }

  init(driver: TaskBackgroundDriver, defaults: UserDefaults) {
    self.driver = driver
    self.defaults = defaults
  }
  func configure() {
    if let old = defaults.string(forKey: "rish.task.background.id") {
      driver.cancel(identifier: old)
      defaults.removeObject(forKey: "rish.task.background.id")
    }
  }
  func begin(runId: String, eligible: Bool, enabled: Bool, foreground: Bool, subtitle: String) {
    precondition(currentRun == nil)
    currentRun = runId
    generation = UUID()
    checkpointRequested = false
    stopped = false
    transitions = 0
    lastStage = subtitle
    guard enabled else { admission = "disabled"; return }
    guard eligible && foreground else { admission = "notEligible"; return }
    guard driver.available else { admission = "unavailable"; return }
    let id = TaskExperience.prefix + "." + UUID().uuidString
    guard driver.register(identifier: id, handler: { [weak self] in self?.accept($0) }) else {
      admission = "registrationRejected"; return
    }
    identifier = id
    do {
      try driver.submit(identifier: id, subtitle: subtitle)
      if handle == nil { admission = "submitted" }
      defaults.set(id, forKey: "rish.task.background.id")
    } catch {
      identifier = nil
      admission = "unavailable"
    }
  }
  func update(stage: String) {
    if stage != lastStage { transitions += 1; lastStage = stage }
    handle?.update(stage: stage, transitions: transitions)
  }
  func enterBackground() {
    guard currentRun != nil, !accepted else { return }
    interrupt(reason: "background_expired")
  }
  func interrupt(reason: String) {
    guard let run = currentRun else { return }
    let ownerGeneration = generation
    stopped = true
    admission = "stopping"
    // Acquire only a bounded saving lease, then notify the actor immediately.
    // Waiting for this lease to expire would allow unadmitted work to continue.
    if !checkpointRequested {
      checkpointRequested = true
      checkpoint = driver.beginCheckpoint { [weak self] in
        guard let self, self.currentRun == run, self.generation == ownerGeneration else { return }
        self.admission = "expired"
        self.onCancel?(run, "background_expired")
        self.finishPermit(success: false)
        self.releaseCheckpoint()
      }
    }
    onCancel?(run, reason)
    if checkpoint == .invalid {
      // The OS denied even a checkpoint lease. Report expiry without claiming
      // that persistence finished; the actor's durable journal owns recovery.
      admission = "expired"
      finishPermit(success: false)
    }
  }
  private func accept(_ task: TaskContinuedHandle) {
    guard task.identifier == identifier, let run = currentRun else {
      task.finish(success: finished[task.identifier] ?? false); return
    }
    handle = task
    if !stopped { admission = "accepted" }
    task.update(stage: lastStage, transitions: transitions)
    let owner = task.identifier
    task.expiration = { [weak self] in
      guard let self, self.currentRun == run, self.identifier == owner else { return }
      // Apple routes both resource expiration and the system Stop control here.
      self.interrupt(reason: "background_expired")
    }
  }
  func end(success: Bool) {
    if let id = identifier {
      finished[id] = success
      finishedOrder.append(id)
      while finishedOrder.count > 32 { finished.removeValue(forKey: finishedOrder.removeFirst()) }
    }
    finishPermit(success: success)
    releaseCheckpoint()
    currentRun = nil
    stopped = false
    admission = "finished"
  }
  private func finishPermit(success: Bool) {
    handle?.finish(success: success)
    handle = nil
    if let id = identifier { driver.cancel(identifier: id) }
    identifier = nil
    defaults.removeObject(forKey: "rish.task.background.id")
  }
  private func releaseCheckpoint() {
    guard checkpoint != .invalid else { return }
    driver.endCheckpoint(checkpoint)
    checkpoint = .invalid
  }
}
