// MARK: - 灵动岛 Live Activity 属性定义
// 对应 ActivityKit 的 CourseActivityAttributes
import ActivityKit
import Foundation

struct CourseActivityAttributes: ActivityAttributes {
    // 静态属性（不随时间变化）
    public struct ContentState: Codable, Hashable {
        // 课程信息
        public var courseName: String
        public var location: String
        // 倒计时文本（系统 timerInterval 驱动，无需手动更新）
        public var countdownText: String
        // 宠物状态
        public var petAction: String       // 动作 ID，如 "nervous", "idle"
        public var petFrame: Int           // 当前帧索引 0-7
        public var bubbleText: String
        // 课程开始/结束时间（用于倒计时计算）
        public var courseStartTime: Date
        public var courseEndTime: Date
    }

    // 常量属性（创建时设置，不可变）
    public var courseId: String
    public var startWeek: Int
    public var endWeek: Int
    public var weekParity: String      // "single"/"double"/"both"

    init(courseId: String, startWeek: Int, endWeek: Int, weekParity: String) {
        self.courseId = courseId
        self.startWeek = startWeek
        self.endWeek = endWeek
        self.weekParity = weekParity
    }
}

// MARK: - 倒计时文本格式器
extension CourseActivityAttributes.ContentState {
    /// 计算剩余时间的格式化文本
    func countdownRemaining(from now: Date = Date()) -> String {
        let diff = max(0, Int(courseStartTime.timeIntervalSince(now)))
        let h = diff / 3600
        let m = (diff % 3600) / 60
        let s = diff % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }
}
