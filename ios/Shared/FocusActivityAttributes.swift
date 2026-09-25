// MARK: - 专注计时灵动岛 Live Activity 属性定义
// 与课表 CourseActivityAttributes 并列，专注开始时启动独立的 Live Activity
import ActivityKit
import Foundation

struct FocusActivityAttributes: ActivityAttributes {
    /// 随时间变化的状态
    public struct ContentState: Codable, Hashable {
        public var start: Date              // 本次计时段起点（暂停恢复后重新校准）
        public var end: Date                // 本次计时段终点（= start + 剩余秒数）
        public var paused: Bool             // 是否暂停中
        public var pauseRemaining: Int      // 暂停时的剩余秒数（恢复时用于重算 end）
        public var petAction: String        // 宠物动作（专注中 idle / 过半 sleepy）
    }

    // 常量属性
    public var taskId: String
    public var taskName: String
    public var goalMinutes: Int             // 本次目标分钟（倒计时总长）
    public var colorIndex: Int              // 与任务卡片同色

    init(taskId: String, taskName: String, goalMinutes: Int, colorIndex: Int) {
        self.taskId = taskId
        self.taskName = taskName
        self.goalMinutes = goalMinutes
        self.colorIndex = colorIndex
    }
}

extension FocusActivityAttributes.ContentState {
    /// 构造运行中状态
    static func running(remainingSeconds: Int, petAction: String) -> FocusActivityAttributes.ContentState {
        let now = Date()
        return ContentState(
            start: now,
            end: now.addingTimeInterval(Double(remainingSeconds)),
            paused: false,
            pauseRemaining: 0,
            petAction: petAction
        )
    }
    /// 构造暂停中状态（pauseTime = now，系统停在剩余秒数）
    static func paused(remainingSeconds: Int, petAction: String) -> FocusActivityAttributes.ContentState {
        let now = Date()
        return ContentState(
            start: now.addingTimeInterval(-Double(remainingSeconds)),
            end: now,
            paused: true,
            pauseRemaining: remainingSeconds,
            petAction: petAction
        )
    }
}
