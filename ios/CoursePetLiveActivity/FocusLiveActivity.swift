// MARK: - 专注计时灵动岛 Widget（正计时：显示已专注多久，暂停时停住）
import ActivityKit
import SwiftUI
import WidgetKit

struct FocusLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: FocusActivityAttributes.self) { context in
            // ── 锁屏横幅 ──
            VStack(spacing: 10) {
                focusBanner(context)
                controls(context)
            }
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
                DynamicIslandExpandedRegion(.bottom) {
                    // 宠物语录 + 控制按钮：让宠物在专注时"说话"还能直接被操作
                    VStack(spacing: 8) {
                        Text("🐾 \(islandStory(context))")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                        controls(context)
                    }
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
                Text("🐾 \(islandStory(context))")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()
        }
    }

    // MARK: - 岛上控制按钮（iOS 17 交互式 Live Activity）
    // iOS 16 不渲染（点岛进 App 操作）；运行中只有暂停，暂停中才有继续+结束，
    // 与 App 内「暂停后才能离开本页」的行为一致。只支持系统按钮样式。
    @ViewBuilder
    private func controls(_ context: ActivityViewContext<FocusActivityAttributes>) -> some View {
        if #available(iOS 17.0, *) {
            if context.state.paused {
                HStack(spacing: 10) {
                    Button(intent: ResumeFocusIntent()) {
                        Label("继续", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .tint(.indigo)
                    Button(intent: EndFocusIntent()) {
                        Label("结束", systemImage: "checkmark.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .tint(.red)
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button(intent: PauseFocusIntent()) {
                    Label("暂停", systemImage: "pause.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.indigo)
            }
        }
    }

    /// 岛上文案：有剧情（本地里程碑 / 服务器任务结果）显示剧情，否则回落内置语录
    private func islandStory(_ context: ActivityViewContext<FocusActivityAttributes>) -> String {
        if let story = context.state.storyText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !story.isEmpty {
            return story
        }
        return focusQuote(context)
    }

    /// 专注语录：按任务名与暂停状态组句，用开始时间做种子确定性选句（重渲染不突变）
    private func focusQuote(_ context: ActivityViewContext<FocusActivityAttributes>) -> String {
        let task = context.attributes.taskName
        let pool: [String] = context.state.paused ? [
            "歇会儿，回来继续",
            "休息一下也没关系，我在",
        ] : [
            "专注\(task)中，我陪你",
            "静下心来，一件一件做",
            "手机放远点，我来帮你守时间",
        ]
        let seed = abs(Int(context.state.start.timeIntervalSince1970) % pool.count)
        return pool[seed]
    }
}
