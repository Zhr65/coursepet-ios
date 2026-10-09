// MARK: - 灵动岛 Live Activity Widget
import ActivityKit
import SwiftUI
import WidgetKit

/// stale 判定（isStale 属性 iOS 16.2+）：Activity 的 staleDate 设为上课时刻，
/// App 死后没人 end 时，系统到点重渲染视图 → 这里返回 true，四态全渲染空，
/// 灵动岛视觉上恢复普通黑岛、锁屏横幅消失，不再卡 0:00
func courseActivityIsStale(_ context: ActivityViewContext<CourseActivityAttributes>) -> Bool {
    if #available(iOS 16.2, *) { return context.isStale }
    return false
}

struct CoursePetLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CourseActivityAttributes.self) { context in
            // 锁屏界面（stale 后渲染空：横幅到点自动消失）
            if courseActivityIsStale(context) {
                Color.clear.frame(height: 0)
            } else {
                CoursePetLiveActivityView(attributes: context.attributes, state: context.state)
            }
        } dynamicIsland: { context in
            DynamicIsland {
                // 展开模式：完整信息（stale 后渲染空）
                DynamicIslandExpandedRegion(.center) {
                    if courseActivityIsStale(context) {
                        Color.clear.frame(height: 0)
                    } else {
                        CoursePetLiveActivityView(attributes: context.attributes, state: context.state)
                            .padding(.horizontal, 4)
                    }
                }
            } compactLeading: {
                // 紧凑模式左侧：宠物真形象（扩展专用极简组件：低内存单帧解码，零动画，
                // 避免 PetAnimationView 撑爆扩展渲染进程导致整岛空白）
                if courseActivityIsStale(context) {
                    Color.clear
                } else {
                    LiveActivitySafePet(
                        action: context.state.petAction,
                        charId: context.state.charId,
                        size: 22
                    )
                }
            } compactTrailing: {
                // 紧凑模式右侧：倒数（课前→上课 / 上课中→下课）
                // 用 timerInterval 倒数 API —— Text(date, style:.timer) 对未来时间不倒数（只正计时）
                if courseActivityIsStale(context) {
                    Color.clear
                } else {
                    Group {
                        if context.state.isClassStarted {
                            Text(timerInterval: Date()...max(Date(), context.state.courseEndTime), countsDown: true)
                        } else {
                            Text(timerInterval: Date()...max(Date(), context.state.courseStartTime), countsDown: true)
                        }
                    }
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundColor(.orange)
                    .frame(maxWidth: 52)
                }
            } minimal: {
                if courseActivityIsStale(context) {
                    Color.clear
                } else {
                    LiveActivitySafePet(
                        action: context.state.petAction,
                        charId: context.state.charId,
                        size: 18
                    )
                }
            }
        }
    }
}
