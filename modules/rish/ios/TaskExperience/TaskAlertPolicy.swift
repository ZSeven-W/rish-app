import Foundation

struct TaskAlertPolicy {
  static func allows(kind: String, enabled: Bool, muted: Bool, foreground: Bool,
                     viewingConversation: Bool, delivered: Bool, sameRun: Bool) -> Bool {
    ["completed", "failed", "attention"].contains(kind) && enabled && !muted &&
      !(foreground && viewingConversation) && !delivered && sameRun
  }
}
