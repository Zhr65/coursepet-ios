// MARK: - 专注计时灵动岛 Live Activity 属性定义
// 专注为正计时（无目标时长）：显示已专注多久；暂停时系统停在当前值
import ActivityKit
import Foundation

struct FocusActivityAttributes: ActivityAttributes {
    /// 随时间变化的状态
    public struct ContentState: Codable, Hashable {
        public var start: Date          // 正计时原点（= 当前时刻 - 已累计秒数）
        public var end: Date            // 正计时上界（start + 24h，远未来即可）
        public var paused: Bool         // 是否暂停中
        public var pauseTime: Date      // 暂停时刻（未暂停时无意义）
        public var petAction: String    // 宠物动作
    }

    // 常量属性
    public var taskId: String
    public var taskName: String
    public var colorIndex: Int          // 与任务卡片同色

    init(taskId: String, taskName: String, colorIndex: Int) {
        self.taskId = taskId
        self.taskName = taskName
        self.colorIndex = colorIndex
    }
}

extension FocusActivityAttributes.ContentState {
    /// 运行中：系统从 start 开始正计时（start = now - 已累计秒数）
    /// 注意：ContentState 会被 ActivityAttributes 协议的同名关联类型遮蔽，构造必须用全名
    static func running(elapsedSeconds: Int, petAction: String) -> FocusActivityAttributes.ContentState {
        let start = Date().addingTimeInterval(-Double(max(0, elapsedSeconds)))
        return FocusActivityAttributes.ContentState(
            start: start,
            end: start.addingTimeInterval(86400),
            paused: false,
            pauseTime: start,
            petAction: petAction
        )
    }

    /// 暂停中：pauseTime 停在当前累计值
    static func paused(elapsedSeconds: Int, petAction: String) -> FocusActivityAttributes.ContentState {
        let now = Date()
        let start = now.addingTimeInterval(-Double(max(0, elapsedSeconds)))
        return FocusActivityAttributes.ContentState(
            start: start,
            end: start.addingTimeInterval(86400),
            paused: true,
            pauseTime: now,
            petAction: petAction
        )
    }
}
