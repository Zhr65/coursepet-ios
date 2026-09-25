// MARK: - 灵动岛 Live Activity Widget
import ActivityKit
import SwiftUI
import WidgetKit

struct CoursePetLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CourseActivityAttributes.self) { context in
            // 锁屏界面
            CoursePetLiveActivityView(attributes: context.attributes, state: context.state)
        } dynamicIsland: { context in
            DynamicIsland {
                // 展开模式：完整信息
                DynamicIslandExpandedRegion(.center) {
                    CoursePetLiveActivityView(attributes: context.attributes, state: context.state)
                        .padding(.horizontal, 4)
                }
            } compactLeading: {
                // 紧凑模式左侧：宠物
                Text("🐾")
            } compactTrailing: {
                // 紧凑模式右侧：倒计时
                Text(context.state.countdownText)
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundColor(.orange)
                    .frame(maxWidth: 44)
            } minimal: {
                Text("🐾")
            }
        }
    }
}
