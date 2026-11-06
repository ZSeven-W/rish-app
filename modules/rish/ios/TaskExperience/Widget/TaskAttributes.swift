import Foundation
import ActivityKit

@available(iOS 16.2, *)
struct RishTaskAttributes: ActivityAttributes {
  struct ContentState: Codable, Hashable {
    var stage: String
    var finished: Bool
  }
  var conversationId: String
  var runId: String
  var startedAt: Date
  var locale: String
}
