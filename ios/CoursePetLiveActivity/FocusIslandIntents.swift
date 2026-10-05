// MARK: - 专注灵动岛交互按钮（iOS 17 交互式 Live Activity 的 App Intent）
// 按钮运行在本扩展进程：直接改 ActivityKit 状态（岛钟立即停/续/消失），
// 再把操作追加进 App Group 命令日志（FocusIslandCommandLog），主 App 回前台
// 时对账本地计时状态。注意：这里禁止触碰 DataManager / 奖励 / 通知 —— 那些都是
// 主 App 进程的职责（Intent 只放扩展 target，不会出现在快捷指令里）。
import ActivityKit
import AppIntents
import Foundation

/// 当前专注 Activity（FocusActivityManager 保证同一时间只有一个）
private func currentFocusActivity() -> Activity<FocusActivityAttributes>? {
    Activity<FocusActivityAttributes>.activities.first
}

/// iOS 16.2 前后差异封装：读 state 后原地改字段再写回（保留 start/pauseTime/charId 不变量）
private func updateFocusActivity(_ activity: Activity<FocusActivityAttributes>,
                                 mutate: (inout FocusActivityAttributes.ContentState) -> Void) {
    var next = activity.contentState
    mutate(&next)
    if #available(iOS 16.2, *) {
        Task { try? await activity.update(ActivityContent(state: next, staleDate: nil)) }
    } else {
        Task { try? await activity.update(using: next) }
    }
}

// MARK: - 暂停
struct PauseFocusIntent: AppIntent {
    static let title: LocalizedStringResource = "暂停专注"
    static let description = IntentDescription("暂停正在进行的专注计时")

    func perform() async throws -> some IntentResult {
        guard let activity = currentFocusActivity(), !activity.contentState.paused else {
            return .result()
        }
        let now = Date()
        let elapsed = max(0, Int(now.timeIntervalSince(activity.contentState.start)))
        updateFocusActivity(activity) { state in
            state.paused = true
            state.pauseTime = now
            state.petAction = "sleep"
            state.storyText = nil   // 清掉运行中剧情，锁屏回落到"歇会儿"语录
        }
        FocusIslandCommandLog.append(.init(action: .pause, epoch: now,
                                           elapsed: elapsed,
                                           taskId: activity.attributes.taskId))
        return .result()
    }
}

// MARK: - 继续
struct ResumeFocusIntent: AppIntent {
    static let title: LocalizedStringResource = "继续专注"
    static let description = IntentDescription("从暂停处继续专注计时")

    func perform() async throws -> some IntentResult {
        guard let activity = currentFocusActivity(), activity.contentState.paused else {
            return .result()
        }
        let state = activity.contentState
        let elapsed = max(0, Int(state.pauseTime.timeIntervalSince(state.start)))
        updateFocusActivity(activity) { s in
            s.paused = false
            s.petAction = "idle"
            s.storyText = nil
        }
        FocusIslandCommandLog.append(.init(action: .resume, epoch: Date(),
                                           elapsed: elapsed,
                                           taskId: activity.attributes.taskId))
        return .result()
    }
}

// MARK: - 结束（仅在暂停态渲染按钮，与 App 内"暂停后才能结束"一致）
struct EndFocusIntent: AppIntent {
    static let title: LocalizedStringResource = "结束专注"
    static let description = IntentDescription("结束本次专注计时并下岛")

    func perform() async throws -> some IntentResult {
        guard let activity = currentFocusActivity() else { return .result() }
        let state = activity.contentState
        let now = Date()
        // 暂停态以 pauseTime 为准；防御性兜底：万一在运行态触发就按当下算
        let elapsed = max(0, Int((state.paused ? state.pauseTime : now).timeIntervalSince(state.start)))
        if #available(iOS 16.2, *) {
            try? await activity.end(nil, dismissalPolicy: .immediate)
        } else {
            try? await activity.end(using: nil, dismissalPolicy: .immediate)
        }
        FocusIslandCommandLog.append(.init(action: .end, epoch: now,
                                           elapsed: elapsed,
                                           taskId: activity.attributes.taskId))
        return .result()
    }
}
