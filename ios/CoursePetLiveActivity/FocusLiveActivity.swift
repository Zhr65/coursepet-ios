// MARK: - 专注计时灵动岛 Widget（正计时：显示已专注多久，暂停时停住）
import ActivityKit
import SwiftUI
import WidgetKit

struct FocusLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: FocusActivityAttributes.self) { context in
            // ── 锁屏横幅 ──
            focusBanner(context)
                .padding(15)
        } dynamicIsland: { context in
            DynamicIsland {
                // ── 展开区：宠物 + 任务名 + 正计时 ──
                DynamicIslandExpandedRegion(.leading) {
                    LiveActivitySafePet(
                        action: context.state.petAction,
                        charId: context.state.charId,
                        size: 40
                    )
                }
                DynamicIslandExpandedRegion(.center) {
                    Text("\(context.state.paused ? "已暂停" : "专注中") · \(context.attributes.taskName)")
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .padding(.horizontal, 2)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    elapsedText(context)
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundColor(context.state.paused ? .orange : .green)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: 110)
                }
            } compactLeading: {
                // 收起区显示真宠物（扩展专用极简组件，低内存单帧零动画）
                LiveActivitySafePet(
                    action: context.state.petAction,
                    charId: context.state.charId,
                    size: 22
                )
            } compactTrailing: {
                elapsedText(context)
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundColor(context.state.paused ? .orange : .green)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(maxWidth: 56)
            } minimal: {
                LiveActivitySafePet(
                    action: context.state.petAction,
                    charId: context.state.charId,
                    size: 18
                )
            }
        }
    }

    /// 正计时文本：系统驱动，暂停时用 pauseTime 停住
    @ViewBuilder
    private func elapsedText(_ context: ActivityViewContext<FocusActivityAttributes>) -> some View {
        Text(timerInterval: context.state.start...context.state.end,
             pauseTime: context.state.paused ? context.state.pauseTime : nil,
             countsDown: false)
    }

    /// 锁屏界面横幅
    @ViewBuilder
    private func focusBanner(_ context: ActivityViewContext<FocusActivityAttributes>) -> some View {
        HStack(spacing: 12) {
            LiveActivitySafePet(
                action: context.state.petAction,
                charId: context.state.charId,
                size: 44
            )

            VStack(alignment: .leading, spacing: 4) {
                Text("\(context.state.paused ? "已暂停" : "专注中") · \(context.attributes.taskName)")
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)
                elapsedText(context)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(context.state.paused ? .orange : .green)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            Spacer()
        }
    }
}
