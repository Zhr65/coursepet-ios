// MARK: - 趣味彩蛋：成就墙（仅主 App 使用）
// 成就解锁状态存本地 UserDefaults（achievement_ids 数组），跨会话保留
import Foundation

enum AchievementManager {
    /// 成就定义（id / 名称 / emoji / 条件说明）
    struct Achievement: Identifiable {
        let id: String
        let name: String
        let emoji: String
        let desc: String
    }

    /// 全部成就清单（顺序即成就墙展示顺序）
    static let allAchievements: [Achievement] = [
        Achievement(id: "first_checkin", name: "首次签到", emoji: "🍙", desc: "完成第一次每日签到"),
        Achievement(id: "streak3", name: "坚持三天", emoji: "🔥", desc: "连续签到 3 天"),
        Achievement(id: "streak7", name: "一周之约", emoji: "🌟", desc: "连续签到 7 天"),
        Achievement(id: "first_feed", name: "初次喂食", emoji: "🍜", desc: "第一次给宠物喂食"),
        Achievement(id: "homework5", name: "作业小能手", emoji: "📖", desc: "累计完成 5 个作业"),
        Achievement(id: "course_adder", name: "课表建筑师", emoji: "🏗️", desc: "添加第一门课程"),
        Achievement(id: "early_bird", name: "早起鸟", emoji: "🐦", desc: "早上 8 点前打开 App"),
    ]

    /// 解锁状态存储键（UserDefaults.standard）
    private static let storageKey = "achievement_ids"

    // MARK: - 查询
    /// 已解锁的成就 id 集合
    static func unlockedIds() -> Set<String> {
        let list = UserDefaults.standard.stringArray(forKey: storageKey) ?? []
        return Set(list)
    }

    /// 已解锁数量
    static var unlockedCount: Int {
        unlockedIds().count
    }

    /// 按成就 id 取定义（弹 toast 显示名称用）
    static func achievement(withID id: String) -> Achievement? {
        allAchievements.first { $0.id == id }
    }

    // MARK: - 解锁
    /// 尝试解锁成就：若尚未解锁则写入并返回 true（调用方可据此弹 toast），已解锁返回 false
    @discardableResult
    static func unlockIfNeeded(_ id: String) -> Bool {
        var list = UserDefaults.standard.stringArray(forKey: storageKey) ?? []
        guard !list.contains(id) else { return false }
        list.append(id)
        UserDefaults.standard.set(list, forKey: storageKey)
        return true
    }
}
