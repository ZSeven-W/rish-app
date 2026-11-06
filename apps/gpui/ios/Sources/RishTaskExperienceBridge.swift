import Foundation
import UIKit

@MainActor
@objc(RishTaskExperienceBridge)
public final class RishTaskExperienceBridge: NSObject {
  private static var pending: Task<Void, Never>?
  private static var eventSink: ((String, NSDictionary) -> Void)?

  @objc(configureWithEmitter:)
  public static func configure(emitter: @escaping (String, NSDictionary) -> Void) {
    eventSink = emitter
    TaskExperience.shared.emit = { action in
      var event: [String: Any] = action
      event["schema_version"] = 1
      eventSink?("taskExperienceAction", event as NSDictionary)
    }
    TaskExperience.shared.configure()
  }
  @objc(handle:completion:)
  public static func handle(_ request: NSDictionary, completion: @escaping (Any?, NSError?) -> Void) {
    let predecessor = pending
    pending = Task { @MainActor in
      await predecessor?.value
      do {
        let bytes = try JSONSerialization.data(withJSONObject: request)
        guard let json = String(data: bytes, encoding: .utf8) else { throw NSError(domain: "RishTaskExperience", code: 1) }
        completion(try await TaskExperience.shared.handle(json), nil)
      } catch { completion(nil, error as NSError) }
    }
  }
  @objc(foregroundChanged:)
  public static func foregroundChanged(_ active: Bool) {
    // This path bypasses the command queue and UI rendering. Expiration and
    // lifecycle actions must reach the process actor even with the UI paused.
    eventSink?("taskExperienceLifecycle", ["schema_version": 1, "foreground": active])
    TaskExperience.shared.foregroundChanged(active)
  }
  @objc(willTerminate)
  public static func willTerminate() { TaskExperience.shared.willTerminate() }
  @objc(openURL:)
  public static func openURL(_ url: URL) -> Bool { TaskExperience.shared.open(url) }
}
