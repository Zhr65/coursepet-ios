// MARK: - 专注计时 Live Activity 管理器
// 专注开始 → 启动灵动岛倒计时（系统 Text(timerInterval:) 自动刷新，无需每秒推送）；
// 暂停/恢复/结束 → 更新或结束 Activity。同一时间只保留一个专注 Activity。
import ActivityKit
import Foundation

enum FocusActivityManager {
    /// 当前剩余秒数的暂存（暂停恢复计算用；App 侧计时状态为准，这里只服务灵动岛）
    private static var lastRemaining: Int = 0

    /// 启动专注灵动岛
    static func start(task: FocusTask, goalSeconds: Int) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        // 已有专注 Activity 先结束，保证只有一个
        endAll()

        let attributes = FocusActivityAttributes(
            taskId: task.id,
            taskName: task.name,
            goalMinutes: goalSeconds / 60,
            colorIndex: task.colorIndex
        )
        let state = FocusActivityAttributes.ContentState.running(
            remainingSeconds: goalSeconds,
            petAction: "idle"
        )
        lastRemaining = goalSeconds
        do {
            _ = try Activity.request(
                attributes: attributes,
                contentState: state,
                pushType: nil
            )
            print("[FocusActivity] 已启动灵动岛：\(task.name)")
        } catch {
            print("[FocusActivity] 启动失败：\(error)")
        }
    }

    /// 暂停（App 内暂停时同步）
    static func pause(remainingSeconds: Int) {
        lastRemaining = remainingSeconds
        update { FocusActivityAttributes.ContentState.paused(remainingSeconds: remainingSeconds, petAction: "idle") }
    }

    /// 恢复
    static func resume(remainingSeconds: Int) {
        lastRemaining = remainingSeconds
        update { FocusActivityAttributes.ContentState.running(remainingSeconds: remainingSeconds, petAction: "idle") }
    }

    /// 正常结束（完成或放弃）：立即消失
    static func end() {
        endAll()
    }

    // MARK: - 内部
    private static func update(_ make: @escaping () -> FocusActivityAttributes.ContentState) {
        for activity in Activity<FocusActivityAttributes>.activities {
            let state = make()
            if #available(iOS 16.2, *) {
                Task { try? await activity.update(ActivityContent(state: state, staleDate: nil)) }
            } else {
                Task { try? await activity.update(using: state) }
            }
        }
    }

    private static func endAll() {
        for activity in Activity<FocusActivityAttributes>.activities {
            if #available(iOS 16.2, *) {
                Task { await activity.end(nil, dismissalPolicy: .immediate) }
            } else {
                Task { await activity.end(using: nil, dismissalPolicy: .immediate) }
            }
        }
    }
}
