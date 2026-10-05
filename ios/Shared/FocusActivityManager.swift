// MARK: - 专注计时 Live Activity 管理器
// 正计时模式：开始 → 灵动岛从 0 起跳；暂停 → 系统停住；继续 → 从累计值续走；
// 结束 → Activity 消失。同一时间只保留一个专注 Activity。
import ActivityKit
import Foundation

enum FocusActivityManager {
    /// 启动专注灵动岛（正计时从 elapsedSeconds 起，一般为 0）
    static func start(task: FocusTask, elapsedSeconds: Int = 0) {
        let enabled = ActivityAuthorizationInfo().areActivitiesEnabled
        LADebug.log("检查专注岛：系统实时活动授权=\(enabled)")
        guard enabled else {
            LADebug.log("拦截：专注岛未授权实时活动")
            return
        }
        // 已有专注 Activity 先结束，保证只有一个
        endAll()

        let attributes = FocusActivityAttributes(
            taskId: task.id,
            taskName: task.name,
            colorIndex: task.colorIndex
        )
        let state = FocusActivityAttributes.ContentState.running(elapsedSeconds: elapsedSeconds, petAction: "idle")
        do {
            let activity = try Activity.request(
                attributes: attributes,
                contentState: state,
                pushType: nil
            )
            LADebug.log("专注岛启动成功：\(task.name)（id=\(activity.id.prefix(8))）")
        } catch {
            LADebug.log("专注岛启动失败：\(error.localizedDescription)")
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

    /// 剧情更新（本地里程碑剧情 / 服务器任务结果上岛）：
    /// read-modify-write 只换 storyText 与宠物动作，保留 start/paused/pauseTime
    /// 计时不变量 —— 严禁用 running(elapsedSeconds:) 重造，岛钟会回跳
    static func updateStory(text: String, petAction: String) {
        let clipped = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clipped.isEmpty else { return }
        for activity in Activity<FocusActivityAttributes>.activities {
            var state = activity.contentState
            state.storyText = String(clipped.prefix(40))  // 锁屏一行放得下
            state.petAction = petAction
            if #available(iOS 16.2, *) {
                Task { try? await activity.update(ActivityContent(state: state, staleDate: nil)) }
            } else {
                Task { try? await activity.update(using: state) }
            }
        }
        LADebug.log("专注岛剧情更新：\(clipped.prefix(16))…")
    }

    /// 退后台保护：把运行中的专注岛 pause 住（系统停在当前累计值，杀 App 期间不会
    /// 继续走）。和 end() 的区别：Activity 还在，回前台可以 resume，切出去看个微信
    /// 回来岛不会消失再重启（只是闪一下暂停→恢复）。elapsed 从 Activity.start 算，
    /// 不需要 App 传。已 paused 的不动。
    static func pauseForBackground() {
        for activity in Activity<FocusActivityAttributes>.activities {
            let state = activity.contentState
            guard !state.paused else { continue }
            let now = Date()
            let elapsed = max(0, Int(now.timeIntervalSince(state.start)))
            var next = state
            next.paused = true
            next.pauseTime = now
            next.petAction = "sleep"
            if #available(iOS 16.2, *) {
                Task { try? await activity.update(ActivityContent(state: next, staleDate: nil)) }
            } else {
                Task { try? await activity.update(using: next) }
            }
        }
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

    // MARK: - 冷启动残留清理
    /// App 冷启动时调用：专注状态只存在于内存，进程被杀后重开必然"专注已丢"，
    /// 但系统里的灵动岛 Activity 不会自动移除（会继续计时 24 小时）——清掉这种孤儿活动。
    /// 只在 init（真正的新进程）调用：从后台恢复（warm）不经过 init，专注中的正常活动不受影响。
    public static func cleanupOrphansOnLaunch() {
        endAll()
    }
}
