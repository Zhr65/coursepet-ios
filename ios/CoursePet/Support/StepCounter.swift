// MARK: - 步数奖励（CoreMotion 读取今日步数 → 宠物 EXP / 食物）
// 里程碑：6000 步 +10 EXP +1 粮；10000 步再 +20 EXP +2 粮（每天各一次）
import Foundation
import CoreMotion

enum StepCounter {
    private static let pedometer = CMPedometer()

    /// 读取今日步数（异步回调；模拟器 / 权限拒绝 / 失败时回调 0）
    static func todaySteps(completion: @escaping (Int) -> Void) {
        guard CMPedometer.isStepCountingAvailable() else {
            DispatchQueue.main.async { completion(0) }
            return
        }
        let start = Calendar.current.startOfDay(for: Date())
        pedometer.queryPedometerData(from: start, to: Date()) { data, _ in
            let steps = Int(data?.numberOfSteps.intValue ?? 0)
            DispatchQueue.main.async { completion(steps) }
        }
    }

    // MARK: - 领奖状态
    private static func claimedKey(_ milestone: Int) -> String { "step.claimed.\(milestone)" }
    private static func claimedDateKey(_ milestone: Int) -> String { "step.claimedDate.\(milestone)" }

    /// 今天该里程碑是否已领（换日后自动重置）
    static func isClaimedToday(milestone: Int) -> Bool {
        let d = StorageLocation.defaults
        return d.string(forKey: claimedDateKey(milestone)) == todayKey()
    }

    /// 领取里程碑奖励：返回 nil 表示领取成功（返回提示文案 = 还没达到步数）
    static func claim(milestone: Int, dataManager: DataManager) -> String? {
        let d = StorageLocation.defaults
        let key = claimedDateKey(milestone)
        // 今天已领过：不重复发
        if d.string(forKey: key) == todayKey() { return nil }
        // 按今天实际步数判断是否达标
        let reached = todayStepsCache >= milestone
        guard reached else { return "还没走到 \(milestone) 步哦" }

        // 发奖：6000 步 +10EXP+1粮，10000 步 +20EXP+2粮
        let exp = milestone == 6000 ? 10 : 20
        let food = milestone == 6000 ? 1 : 2
        _ = dataManager.addEXP(exp)
        var s = dataManager.loadState()
        s.pet.food = min(99, s.pet.food + food)
        s.pet.currentAction = "happy"
        dataManager.saveState(s)

        // 记录领取标记
        d.set(true, forKey: claimedKey(milestone))
        d.set(todayKey(), forKey: key)
        return nil
    }

    /// 今日步数缓存（视图刷新时更新，领奖判断用）
    static var todayStepsCache: Int = 0

    private static func todayKey() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd"
        return f.string(from: Date())
    }
}
