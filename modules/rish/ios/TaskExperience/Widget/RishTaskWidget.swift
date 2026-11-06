import ActivityKit
import WidgetKit
import SwiftUI

@main
struct RishTaskWidgets: WidgetBundle {
  var body: some Widget { RishTaskWidget() }
}
struct RishTaskWidget: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: RishTaskAttributes.self) { context in
      HStack(spacing: 12) {
        Image(systemName: context.state.finished ? "checkmark.circle" : "terminal")
        VStack(alignment: .leading, spacing: 4) {
          Text("Rish").font(.headline)
          Text(context.isStale ? (context.attributes.locale.hasPrefix("zh") ? "返回 Rish 更新状态" : "Open Rish to refresh status") : context.state.stage).font(.subheadline)
        }
        Spacer()
        if #available(iOS 17.0, *), !context.state.finished, !context.isStale {
          Button(intent: RishCancelTaskIntent(runId: context.attributes.runId, conversationId: context.attributes.conversationId)) {
            Image(systemName: "stop.circle")
          }.accessibilityLabel(context.attributes.locale.hasPrefix("zh") ? "停止任务" : "Stop task")
        }
        if !context.state.finished { Text(context.attributes.startedAt, style: .timer).monospacedDigit() }
      }
      .padding().activityBackgroundTint(.black).activitySystemActionForegroundColor(.white)
      .foregroundStyle(.white)
      .widgetURL(taskURL(context.attributes))
    } dynamicIsland: { context in
      DynamicIsland {
        DynamicIslandExpandedRegion(.leading) { Label("Rish", systemImage: "terminal") }
        DynamicIslandExpandedRegion(.trailing) {
          if !context.state.finished { Text(context.attributes.startedAt, style: .timer).monospacedDigit() }
        }
        DynamicIslandExpandedRegion(.bottom) {
          VStack(spacing: 8) {
            Text(context.isStale ? (context.attributes.locale.hasPrefix("zh") ? "返回 Rish 更新状态" : "Open Rish to refresh status") : context.state.stage)
            HStack {
              Link(context.attributes.locale.hasPrefix("zh") ? "打开任务" : "Open task", destination: taskURL(context.attributes))
              if #available(iOS 17.0, *), !context.state.finished, !context.isStale {
                Button(intent: RishCancelTaskIntent(runId: context.attributes.runId, conversationId: context.attributes.conversationId)) {
                  Text(context.attributes.locale.hasPrefix("zh") ? "停止任务" : "Stop task")
                }
              }
            }
          }
        }
      } compactLeading: { Image(systemName: "terminal") }
      compactTrailing: { Image(systemName: context.state.finished ? "checkmark" : context.isStale ? "exclamationmark" : "ellipsis") }
      minimal: { Image(systemName: "terminal") }
      .widgetURL(taskURL(context.attributes))
    }
  }
  private func taskURL(_ attributes: RishTaskAttributes) -> URL {
    var url = URLComponents()
    url.scheme = "rish"; url.host = "task"
    url.queryItems = [URLQueryItem(name: "conversation", value: attributes.conversationId), URLQueryItem(name: "run", value: attributes.runId)]
    return url.url!
  }
}
