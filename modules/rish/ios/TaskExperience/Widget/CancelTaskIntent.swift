import AppIntents

@available(iOS 17.0, *)
struct RishCancelTaskIntent: LiveActivityIntent {
  static var title: LocalizedStringResource = "Stop Rish task"
  static var isDiscoverable = false
  static var openAppWhenRun = true
  @Parameter(title: "Run") var runId: String
  @Parameter(title: "Conversation") var conversationId: String
  init() {}
  init(runId: String, conversationId: String) { self.runId = runId; self.conversationId = conversationId }
  func perform() async throws -> some IntentResult {
#if RISH_TASK_HOST
    await TaskExperience.shared.cancelFromActivity(runId: runId, conversationId: conversationId)
#endif
    return .result()
  }
}
