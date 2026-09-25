// MARK: - 专注计时灵动岛 Widget（独立于课表 Live Activity）
// 倒计时用系统 Text(timerInterval:) / ProgressView(timerInterval:) 自动刷新，无需推送更新
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
                // ── 展开区：任务名 + 宠物 + 进度条 + 剩余时间 ──
                DynamicIslandExpandedRegion(.leading) {
                    PetAnimationView(
                        action: context.state.petAction,
                        charId: "char1",
                        speed: .mid,
                        size: 40,
                        loop: false,
                        liveActivityMode: true
                    )
                    .frame(width: 40, height: 40)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("专注中 · \(context.attributes.taskName)")
                            .font(.system(size: 14, weight: .semibold))
                            .lineLimit(1)
                        // 系统自动推进的进度条（暂停时同样自动停）
                        ProgressView(timerInterval: context.state.start...context.state.end,
                                     countsDown: false)
                            .progressViewStyle(.linear)
                            .tint(Color(hue: Double(context.attributes.colorIndex) / 6.0, saturation: 0.55, brightness: 0.95))
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    // 剩余倒计时（系统驱动，暂停时用 pauseTime 停住）
                    Text(timerInterval: context.state.start...context.state.end,
                         pauseTime: context.state.paused ? context.state.end : nil,
                         countsDown: true)
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundColor(.green)
                        .frame(maxWidth: 88)
                }
            } compactLeading: {
                Text("🍅")
            } compactTrailing: {
                Text(timerInterval: context.state.start...context.state.end,
                     pauseTime: context.state.paused ? context.state.end : nil,
                     countsDown: true)
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundColor(.green)
                    .frame(maxWidth: 44)
            } minimal: {
                Text("🍅")
            }
        }
    }

    /// 锁屏界面横幅
    @ViewBuilder
    private func focusBanner(_ context: ActivityViewContext<FocusActivityAttributes>) -> some View {
        HStack(spacing: 12) {
            PetAnimationView(
                action: context.state.petAction,
                charId: "char1",
                speed: .mid,
                size: 44,
                loop: false,
                liveActivityMode: true
            )
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 4) {
                Text(context.state.paused ? "已暂停 · \(context.attributes.taskName)" : "专注中 · \(context.attributes.taskName)")
                    .font(.system(size: 14, weight: .semibold))
                ProgressView(timerInterval: context.state.start...context.state.end,
                             countsDown: false)
                    .progressViewStyle(.linear)
                    .tint(Color(hue: Double(context.attributes.colorIndex) / 6.0, saturation: 0.55, brightness: 0.95))
            }

            Spacer()

            Text(timerInterval: context.state.start...context.state.end,
                 pauseTime: context.state.paused ? context.state.end : nil,
                 countsDown: true)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundColor(.green)
                .frame(maxWidth: 96)
        }
    }
}
