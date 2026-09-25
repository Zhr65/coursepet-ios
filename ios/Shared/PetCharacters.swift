// MARK: - 宠物形象目录（形象商店）
// 9 只形象：char1-4 默认解锁；char5-9 通过养成行为解锁（等级 / 累计专注 / 连续打卡）。
// 解锁为动态判定：条件达成即自动解锁，无需持久化额外状态（换机恢复备份后同样成立）。
// 帧图来源：App Bundle AppPetAssets/{charId}/，由 PetAssetInstaller 启动时装入 App Group。
import Foundation

struct PetCharacter: Identifiable {
    enum Unlock: Equatable {
        case free
        case level(Int)          // 宠物等级达到
        case focusHours(Int)     // 累计专注时长达到（小时）
        case checkInStreak(Int)  // 连续打卡天数达到
    }

    let id: String
    let name: String
    let unlock: Unlock

    var unlockText: String {
        switch unlock {
        case .free: return "默认可用"
        case .level(let lv): return "等级达到 Lv.\(lv)"
        case .focusHours(let h): return "累计专注 \(h) 小时"
        case .checkInStreak(let d): return "连续打卡 \(d) 天"
        }
    }

    /// 是否已解锁（调用方传入当前等级 / 专注分钟数 / 连续打卡天数）
    func isUnlocked(level: Int, focusMinutes: Int, streak: Int) -> Bool {
        switch unlock {
        case .free: return true
        case .level(let lv): return level >= lv
        case .focusHours(let h): return focusMinutes >= h * 60
        case .checkInStreak(let d): return streak >= d
        }
    }

    /// 解锁进度 0~1（商店卡片进度条）
    func progress(level: Int, focusMinutes: Int, streak: Int) -> Double {
        switch unlock {
        case .free: return 1
        case .level(let lv): return min(1, Double(level) / Double(lv))
        case .focusHours(let h): return min(1, Double(focusMinutes) / Double(h * 60))
        case .checkInStreak(let d): return min(1, Double(streak) / Double(d))
        }
    }
}

enum PetCatalog {
    static let all: [PetCharacter] = [
        .init(id: "char1", name: "小狼", unlock: .free),
        .init(id: "char2", name: "猪护士", unlock: .free),
        .init(id: "char3", name: "小青蛙", unlock: .free),
        .init(id: "char4", name: "小猫咪", unlock: .free),
        .init(id: "char5", name: "炸毛猫", unlock: .level(5)),
        .init(id: "char6", name: "刘海狗", unlock: .level(10)),
        .init(id: "char7", name: "蛋壳鸡", unlock: .focusHours(10)),
        .init(id: "char8", name: "榴莲刺猬", unlock: .checkInStreak(7)),
        .init(id: "char9", name: "小黑驴", unlock: .level(15)),
    ]

    static func character(id: String) -> PetCharacter? {
        return all.first { $0.id == id }
    }
}
