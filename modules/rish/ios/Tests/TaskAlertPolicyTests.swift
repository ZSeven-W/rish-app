import XCTest

final class TaskAlertPolicyTests: XCTestCase {
  func testPrivacyAndDeduplicationMatrix() {
    for mask in 0..<128 {
      let enabled = mask & 1 != 0, muted = mask & 2 != 0
      let foreground = mask & 4 != 0, visible = mask & 8 != 0
      let delivered = mask & 16 != 0, sameRun = mask & 32 != 0
      let kind = mask & 64 != 0 ? "attention" : "completed"
      let expected = enabled && !muted && !(foreground && visible) && !delivered && sameRun
      XCTAssertEqual(TaskAlertPolicy.allows(kind: kind, enabled: enabled, muted: muted,
        foreground: foreground, viewingConversation: visible, delivered: delivered, sameRun: sameRun), expected)
    }
  }
  func testUnknownEventsCannotNotify() {
    XCTAssertFalse(TaskAlertPolicy.allows(kind: "raw_message", enabled: true, muted: false,
      foreground: false, viewingConversation: false, delivered: false, sameRun: true))
  }
}
