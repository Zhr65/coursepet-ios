// MARK: - 宠物事件主动提醒（"它盯着你"的第一块拼图）
// 思路：数据变化（平台同步新作业等）不再默默入库，而是让宠物"看到"并开口说话。
// 链路：事件 → 冷却/打扰上限 → 组装上下文 → LLM 生成口吻文案（无 Key 回落模板）
//       → 本地通知（前台也弹）+ Bark 镜像（App 关着也收得到）。
// 打扰克制三原则：同类 30 分钟冷却、每天上限 6 条、首绑导入不刷屏。
import Foundation
import UserNotifications

enum PetEventNudger {

    /// 事件类型（后续按需扩展：课表变更 / 快递变化 / DDL 提前…）
    enum Event {
        /// 平台同步进来新作业（可能多平台混合，平台名随 item 走）
        case newHomework(items: [(title: String, course: String?, due: Date?, platform: String)])
    }

    // MARK: 开关（设置页"通知与播报"区，与晨报/周报并列）
    static var isEnabled: Bool {
        get { StorageLocation.defaults.object(forKey: "settings.eventNudgeEnabled") as? Bool ?? true }
        set { StorageLocation.defaults.set(newValue, forKey: "settings.eventNudgeEnabled") }
    }

    /// 同类事件冷却：30 分钟内同一类只说一次（避免反复回前台重复轰炸）
    private static let cooldown: TimeInterval = 30 * 60
    /// 每日上限：宁可不发，也不能变成通知机器
    private static let dailyLimit = 6

    // MARK: - 事件入口（事件发生时调用；MainActor 保证数据读取一致）
    @MainActor
    static func nudge(_ event: Event) {
        guard isEnabled else { return }
        let ud = StorageLocation.defaults

        // ① 每日总量上限（滚动按天计数）
        let dayId = Self.dayId(Date())
        let countKey = "nudge.count.\(dayId)"
        guard ud.integer(forKey: countKey) < dailyLimit else { return }

        // ② 同类冷却
        let coolKey = "nudge.last.\(cooldownName(event))"
        if let last = ud.object(forKey: coolKey) as? Date,
           Date().timeIntervalSince(last) < cooldown { return }

        // 过了闸门才计数（宁可少发，不可多发）
        ud.set(Date(), forKey: coolKey)
        ud.set(ud.integer(forKey: countKey) + 1, forKey: countKey)

        // ③ 组装上下文与模板文案（模板永远先备好——LLM 挂了也有话可说）
        let fallback = templateText(event)
        let llmInput = llmContext(event)
        let title = eventTitle(event)

        Task { @MainActor in
            // ④ LLM 口吻生成：配置了端侧 Key 就让它说人话，失败回落模板
            let spoken = await AgentQuickLLM.ask(system: Self.systemPrompt, user: llmInput)
            announce(title: title, body: spoken ?? fallback)
        }
    }

    // MARK: - 发送（本地通知 + Bark 镜像）
    private static func announce(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "coursepet_nudge_\(UUID().uuidString)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
        BarkPush.send(title: title, body: body, group: "CoursePet事件")
    }

    // MARK: - 模板文案（LLM 不可用时的保底，信息量优先）
    @MainActor
    private static func templateText(_ event: Event) -> String {
        switch event {
        case let .newHomework(items):
            let platforms = Set(items.map { $0.platform })
            let source = platforms.count == 1 ? platforms.first! : "平台"
            var lines: [String] = []
            if items.count == 1, let first = items.first {
                lines.append("\(first.title)\(dueText(first.due))")
            } else if items.count <= 3 {
                for item in items {
                    lines.append("· \(item.title)\(dueText(item.due))")
                }
            } else {
                // 超过 3 个只列最近的一个，防止通知变成刷屏
                if let nearest = items.min(by: { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }) {
                    lines.append("最近的一个：\(nearest.title)\(dueText(nearest.due))")
                }
            }
            var body = "\(source)同步进来 \(items.count) 个新作业：\n" + lines.joined(separator: "\n")
            // 附一条最相关的上下文：未完成作业总量
            let pending = DataManager.shared.homeworks.filter { !$0.isDone }.count
            if pending > items.count {
                body += "\n现在手里还有 \(pending) 件事没清。"
            }
            return body
        }
    }

    /// 截止时间人话化：" · 周五 23:59 截止"；解析不出就不提
    private static func dueText(_ due: Date?) -> String {
        guard let due else { return "" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "EEE HH:mm"   // EEE 在 zh_CN 下输出"周五"（EEEE 是"星期五"，太长）
        return " · \(f.string(from: due))截止"
    }

    // MARK: - LLM 上下文（把事件 + 环境状态交给模型，让它说得像个懂你的朋友）
    @MainActor
    private static func llmContext(_ event: Event) -> String {
        var parts: [String] = []
        switch event {
        case let .newHomework(items):
            let f = DateFormatter()
            f.locale = Locale(identifier: "zh_CN")
            f.dateFormat = "EEEE HH:mm"
            let desc = items.prefix(5).map { item in
                "《\(item.title)》\(item.course.map { "(\($0))" } ?? "")\(item.due.map { "\(f.string(from: $0))截止" } ?? "")（来自\(item.platform)）"
            }.joined(separator: "、")
            parts.append("事件：刚同步了 \(items.count) 个新作业：\(desc)")
        }
        // 环境状态：今天还剩什么、手里压着多少活（让宠物把话说在点子上）
        parts.append(todayContext())
        let pending = DataManager.shared.homeworks.filter { !$0.isDone }.count
        parts.append("当前未完成作业共 \(pending) 个。")
        return parts.joined(separator: "\n")
    }

    /// 今日课表剩余情况（有课才提，别浪费字数）
    @MainActor
    private static func todayContext() -> String {
        let dm = DataManager.shared
        guard let week = WeekMath.currentWeekNumber(startDateStr: dm.semesterStartDate) else {
            return "今天没课。"
        }
        let dow = Calendar.current.component(.weekday, from: Date())
        let dayOfWeek = dow == 1 ? 7 : dow - 1   // Calendar 周日=1 → 课表周一=1..周日=7
        let todays = ScheduleHelpers.courses(forWeek: week, courses: dm.courses)
            .filter { $0.dayOfWeek == dayOfWeek }
            .sorted { (ScheduleHelpers.timeToMinutes($0.startTime) ?? 0) < (ScheduleHelpers.timeToMinutes($1.startTime) ?? 0) }
        guard !todays.isEmpty else { return "今天没课。" }
        let now = Date()
        let upcoming = todays.filter {
            (ScheduleHelpers.timeToMinutes($0.startTime) ?? 0) > Calendar.current.component(.hour, from: now) * 60
                + Calendar.current.component(.minute, from: now)
        }
        if upcoming.isEmpty { return "今天的课都上完了。" }
        let brief = upcoming.prefix(2).map { "\($0.startTime) 《\($0.name)》" }.joined(separator: "、")
        return "今天还有 \(upcoming.count) 节课：\(brief)"
    }

    // MARK: - LLM 人设（短、口语、朋友味；与聊天守则同调但更狠地限长）
    private static let systemPrompt = """
    你是用户的宠物管家，现在要针对一件事主动提醒用户。说话像朋友发微信：一句话，不超过 40 字，口语，可以有一点点调侃但别贫。禁止 markdown、禁止列表、禁止换行。把最要紧的信息（作业名、截止时间）说到。
    """

    // MARK: - 小工具
    private static func eventTitle(_ event: Event) -> String {
        switch event {
        case .newHomework: return "📖 宠物发现有新作业"
        }
    }

    private static func cooldownName(_ event: Event) -> String {
        switch event {
        case .newHomework: return "newHomework"
        }
    }

    private static func dayId(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd"
        return f.string(from: date)
    }
}
