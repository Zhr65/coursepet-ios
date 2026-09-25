// MARK: - 专注计时 Live Activity 管理器
// 正计时模式：开始 → 灵动岛从 0 起跳；暂停 → 系统停住；继续 → 从累计值续走；
// 结束 → Activity 消失。同一时间只保留一个专注 Activity。
import ActivityKit
import Foundation

enum FocusActivityManager {
    /// 启动专注灵动岛（正计时从 elapsedSeconds 起，一般为 0）
    static func start(task: FocusTask, elapsedSeconds: Int = 0) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        // 已有专注 Activity 先结束，保证只有一个
        endAll()

        let attributes = FocusActivityAttributes(
            taskId: task.id,
            taskName: task.name,
            colorIndex: task.colorIndex
        )
        let state = FocusActivityAttributes.ContentState.running(elapsedSeconds: elapsedSeconds, petAction: "idle")
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

    /// 暂停（系统停在 elapsedSeconds，宠物睡觉示意"打盹"）
    static func pause(elapsedSeconds: Int) {
        update { .paused(elapsedSeconds: elapsedSeconds, petAction: "sleep") }
    }

    /// 继续（从 elapsedSeconds 续走）
    static func resume(elapsedSeconds: Int) {
        update { .running(elapsedSeconds: elapsedSeconds, petAction: "idle") }
    }

    /// 结束：立即消失
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
