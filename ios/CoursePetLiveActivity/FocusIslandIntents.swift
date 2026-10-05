// MARK: - 专注灵动岛交互按钮（iOS 17 交互式 Live Activity 的 App Intent）
// 按钮运行在本扩展进程：直接改 ActivityKit 状态（岛钟立即停/续/消失），
// 再把操作追加进 App Group 命令日志（FocusIslandCommandLog），主 App 回前台
// 时对账本地计时状态。注意：这里禁止触碰 DataManager / 奖励 / 通知 —— 那些都是
// 主 App 进程的职责（Intent 只放扩展 target，不会出现在快捷指令里）。
//
// ⚠️ 关键：perform() 里所有 ActivityKit 调用必须 await 同步执行！
// Intent 返回 .result() 后系统会立即终止扩展进程，fire-and-forget Task 会被 cancel，
// 导致 activity.update / activity.end 静默失败（按钮点了没反应）。
import ActivityKit
import AppIntents
import Foundation

/// 当前专注 Activity（FocusActivityManager 保证同一时间只有一个）
private func currentFocusActivity() -> Activity<FocusActivityAttributes>? {
    Activity<FocusActivityAttributes>.activities.first
}

/// iOS 16.2 前后差异封装：**await 同步** update（Intent 不能 fire-and-forget）
private func updateFocusActivity(_ activity: Activity<FocusActivityAttributes>,
                                 mutate: (inout FocusActivityAttributes.ContentState) -> Void) async {
    var next = activity.contentState
    mutate(&next)
    if #available(iOS 16.2, *) {
        try? await activity.update(ActivityContent(state: next, staleDate: nil))
    } else {
        try? await activity.update(using: next)
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
        // ⚠️ await 同步！Task { } 在 Intent 返回后会被 cancel
        await updateFocusActivity(activity) { state in
            state.paused = true
            state.pauseTime = now
            state.petAction = "sleep"
            state.storyText = nil
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
        await updateFocusActivity(activity) { s in
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

// MARK: - 结束
struct EndFocusIntent: AppIntent {
    static let title: LocalizedStringResource = "结束专注"
    static let description = IntentDescription("结束本次专注计时并下岛")

    func perform() async throws -> some IntentResult {
        guard let activity = currentFocusActivity() else { return .result() }
        let state = activity.contentState
        let now = Date()
        let elapsed = max(0, Int((state.paused ? state.pauseTime : now).timeIntervalSince(state.start)))
        // ⚠️ await 同步！end 也不能 fire-and-forget
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
