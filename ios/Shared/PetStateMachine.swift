// MARK: - 宠物状态机（移植自 prototype/js/pet-state.js）
import Foundation

public struct PetActionResult {
    public let action: String      // 动作 ID，对应 pet_assets 中的文件名前缀
    public let bubble: String      // 气泡文字
}

public struct PetStateManager {
    // 与 Web 原型 CLICK_BUBBLES 一致
    private static let clickBubbles = [
        "嘿嘿，找我玩吗？", "今天也要加油鸭！", "最喜欢你啦～", "好无聊，陪我玩一会儿嘛"
    ]

    /// 根据心情返回气泡文字
    public static func bubble(for mood: Int, random: @escaping () -> Double = { Double.random(in: 0..<1) }) -> String {
        let pick: ([String]) -> String = { arr in arr[Int(random() * Double(arr.count))] }
        if mood >= 80 { return pick(["今天状态满分！", "有你在真好～", "冲鸭！"]) }
        if mood <= 30 { return pick(["好饿…想被投喂", "没什么精神…", "陪我玩一会儿嘛"]) }
        return pick(["下节课在哪栋楼？", "今天也要加油鸭", "好困啊…"])
    }

    /// 主状态机入口
    /// - Parameters:
    ///   - courses: 已按当前周过滤的课程列表
    ///   - charging: 是否正在充电
    ///   - lowBattery: 电量是否低于 20%
    ///   - musicPlaying: 是否正在播放音乐
    ///   - lastClickAt: 最近一次点击宠物的时间
    ///   - rand: 可注入随机源便于测试
    public static func decideAction(
        courses: [Course],
        charging: Bool = false,
        lowBattery: Bool = false,
        musicPlaying: Bool = false,
        lastClickAt: Date? = nil,
        now: Date = Date(),
        random: @escaping () -> Double = { Double.random(in: 0..<1) }
    ) -> PetActionResult {
        // 优先级 1：充电
        if charging { return PetActionResult(action: "charge", bubble: "充得满满哒～") }
        // 优先级 2：低电量
        if lowBattery { return PetActionResult(action: "weak", bubble: "电量告急，帮我充个电吧…") }
        // 优先级 3：听音乐
        if musicPlaying { return PetActionResult(action: "listen", bubble: "") }
        // 优先级 4：最近点击（5秒内）
        if let lastClick = lastClickAt, now.timeIntervalSince(lastClick) < 5 {
            let action = random() < 0.5 ? "happy" : "excite"
            let bubble = clickBubbles[Int(random() * Double(clickBubbles.count))]
            return PetActionResult(action: action, bubble: bubble)
        }
        // 优先级 5：课前 15 分钟内 → nervous
        let result = ScheduleHelpers.currentAndNext(courses: courses, at: now)
        if let next = result.next, (next.startDate.timeIntervalSince(now) / 60) <= 15 {
            return PetActionResult(action: "nervous", bubble: "下节课要迟到了！")
        }
        // 优先级 6：上课中 → idle 或 sleep
        if let current = result.current {
            return random() < 0.2
                ? PetActionResult(action: "sleep", bubble: "zzZ…")
                : PetActionResult(action: "idle", bubble: "")
        }
        // 优先级 7：课后 10 分钟内 → walk 或 excite
        let calendar = Calendar.current
        let curMin = calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)
        let dow: Int = { let g = calendar.component(.weekday, from: now); return g == 1 ? 7 : g - 1 }()
        let ended = courses
            .filter { $0.dayOfWeek == dow }
            .compactMap { course in
                guard let e = ScheduleHelpers.timeToMinutes(course.endTime) else { return nil }
                return (course, e)
            }
            .filter { $0.1 <= curMin }
            .sorted { $0.1 > $1.1 }  // 按结束时间降序
        if let lastEnded = ended.first, curMin - lastEnded.1 <= 10 {
            return random() < 0.5
                ? PetActionResult(action: "walk", bubble: "下课啦！")
                : PetActionResult(action: "excite", bubble: "下课啦！")
        }
        // 默认：idle
        return PetActionResult(action: "idle", bubble: "")
    }
}
