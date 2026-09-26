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
                // 紧凑模式左侧：宠物真形象（优先 App Group / 内置 PNG 帧；无图时显示爪印，绝不用团子兜底）
                PetAnimationView(
                    action: context.state.petAction,
                    charId: "char1",
                    speed: .mid,
                    size: 22,
                    loop: true,
                    liveActivityMode: true,
                    noPngFallbackEmoji: true
                )
                .frame(width: 22, height: 22)
            } compactTrailing: {
                // 紧凑模式右侧：倒计时/正计时（系统 timer 驱动，实时跳动不耗更新预算）
                // 课前 → 倒数到上课；上课中 → 从上课时刻正计时
                Text(context.state.courseStartTime, style: .timer)
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundColor(.orange)
                    .frame(maxWidth: 52)
            } minimal: {
                PetAnimationView(
                    action: context.state.petAction,
                    charId: "char1",
                    speed: .mid,
                    size: 18,
                    loop: true,
                    liveActivityMode: true,
                    noPngFallbackEmoji: true
                )
                .frame(width: 18, height: 18)
            }
        }
    }
}
