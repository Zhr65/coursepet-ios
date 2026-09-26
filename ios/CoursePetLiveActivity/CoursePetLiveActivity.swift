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
                // 紧凑模式左侧：宠物真形象（扩展专用极简组件：低内存单帧解码，零动画，
                // 避免 PetAnimationView 撑爆扩展渲染进程导致整岛空白）
                LiveActivitySafePet(
                    action: context.state.petAction,
                    charId: context.state.charId,
                    size: 22
                )
            } compactTrailing: {
                // 紧凑模式右侧：课前倒数到上课 / 上课中倒数到下课（系统 timer 驱动）
                if context.state.isClassStarted {
                    Text(context.state.courseEndTime, style: .timer)
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundColor(.orange)
                        .frame(maxWidth: 52)
                } else {
                    Text(context.state.courseStartTime, style: .timer)
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundColor(.orange)
                        .frame(maxWidth: 52)
                }
            } minimal: {
                LiveActivitySafePet(
                    action: context.state.petAction,
                    charId: context.state.charId,
                    size: 18
                )
            }
        }
    }
}
