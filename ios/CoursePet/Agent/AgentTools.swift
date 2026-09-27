// MARK: - Agent 工具注册表（端侧工具层）
// 每个 AgentTool = 给模型看的"说明书"（JSON Schema）+ 本地执行的闭包。
// 设计原则：模型只负责"决定调什么、传什么参数"，所有数据读写都在端侧完成，
// 原始数据不出设备——LLM 拿到的只有工具执行后的摘要文本。
import Foundation

struct AgentTool {
    let name: String                       // 模型可见的工具名（英文 snake_case）
    let description: String                // 告诉模型什么时候该用这个工具
    let parametersSchema: [String: Any]    // JSON Schema，描述参数结构
    /// 实际执行体：入参为模型给的参数字典，返回给模型的摘要文本
    let execute: ([String: Any]) async throws -> String
}

enum AgentToolRegistry {

    // 记账六分类（与语音记账模块保持一致）
    static let ledgerCategories = ["餐饮", "日用", "学习", "娱乐", "交通", "其他"]

    /// 组装全部工具（传入 DataManager 读取真实数据）
    static func allTools(dataManager: DataManager) -> [AgentTool] {
        let dm = dataManager
        return [
            // ── 1. 查今日课表 ──────────────────────────────
            AgentTool(
                name: "get_today_schedule",
                description: "查询用户今天（按当前学期周数过滤单双周）的全部课程，含时间、教室、老师。",
                parametersSchema: ["type": "object", "properties": [:] as [String: Any]],
                execute: { _ in
                    guard let week = WeekMath.currentWeekNumber(startDateStr: dm.semesterStartDate) else {
                        return "尚未设置开学日期，无法确定当前周数。建议用户到设置页设置开学日期。"
                    }
                    let todayDow = Self.currentDayOfWeek()
                    let weekCourses = ScheduleHelpers.courses(forWeek: week, courses: dm.courses)
                    let todays = weekCourses.filter { $0.dayOfWeek == todayDow }
                        .sorted { (ScheduleHelpers.timeToMinutes($0.startTime) ?? 0) < (ScheduleHelpers.timeToMinutes($1.startTime) ?? 0) }
                    guard !todays.isEmpty else { return "今天（周\(todayDow)）没有课，是空闲日。" }
                    let lines = todays.map { c in
                        "\(c.startTime)-\(c.endTime) 《\(c.name)》\(c.location.isEmpty ? "教室未填" : "@\(c.location))")\(c.teacher.isEmpty ? "" : " · \(c.teacher)")"
                    }
                    return "今天是学期第\(week)周，周\(todayDow)。今日课程：\n" + lines.joined(separator: "\n")
                }
            ),

            // ── 2. 查下一节课 ──────────────────────────────
            AgentTool(
                name: "get_next_class",
                description: "查询当前正在上的课或下一节课（含开始时间和教室）。用户问'接下来有什么课/现在该去哪'时使用。",
                parametersSchema: ["type": "object", "properties": [:] as [String: Any]],
                execute: { _ in
                    guard let week = WeekMath.currentWeekNumber(startDateStr: dm.semesterStartDate) else {
                        return "尚未设置开学日期，无法查询课程。"
                    }
                    let (current, next) = ScheduleHelpers.currentAndNext(courses: dm.courses, at: Date())
                    if let c = current {
                        return "当前正在上课：《\(c.name)》\(c.startTime)-\(c.endTime)，教室：\(c.location.isEmpty ? "未填" : c.location)。"
                    }
                    if let n = next {
                        let mins = Int(n.startDate.timeIntervalSinceNow / 60)
                        return "当前没有课。下一节：《\(n.course.name)》\(n.course.startTime) 开始（约 \(max(0, mins)) 分钟后），教室：\(n.course.location.isEmpty ? "未填" : n.course.location)。"
                    }
                    return "今天接下来的课程已全部结束。"
                }
            ),

            // ── 3. 查未完成作业 ────────────────────────────
            AgentTool(
                name: "get_pending_homeworks",
                description: "查询全部未完成的作业/待办（按截止时间排序，最紧急在前）。用户问'我有什么事没做/DDL'时使用。",
                parametersSchema: ["type": "object", "properties": [:] as [String: Any]],
                execute: { _ in
                    let pending = dm.homeworks.filter { !$0.isDone }
                    guard !pending.isEmpty else { return "没有未完成的作业，全部清空！🎉" }
                    let formatter = DateFormatter()
                    formatter.dateFormat = "M月d日 HH:mm"
                    let lines = pending.map { hw -> String in
                        if let due = hw.dueDate {
                            let overdue = due < Date() ? "（已过期！）" : ""
                            return "《\(hw.title)》截止 \(formatter.string(from: due))\(overdue)\(hw.courseName.map { " · \($0)" } ?? "")"
                        }
                        return "《\(hw.title)》（无截止时间）"
                    }
                    return "未完成作业 \(pending.count) 个：\n" + lines.joined(separator: "\n")
                }
            ),

            // ── 4. 添加作业 ────────────────────────────────
            AgentTool(
                name: "add_homework",
                description: "为用户添加一条作业/待办。用户说'帮我记一下要做XX'时使用。dueDate 格式为 yyyy-MM-dd HH:mm，用户没说截止时间就不传。",
                parametersSchema: [
                    "type": "object",
                    "properties": [
                        "title": ["type": "string", "description": "作业标题，如：高数第三章习题"],
                        "courseName": ["type": "string", "description": "关联课程名，可选"],
                        "dueDate": ["type": "string", "description": "截止时间，格式 yyyy-MM-dd HH:mm，可选"]
                    ],
                    "required": ["title"]
                ],
                execute: { args in
                    guard let title = args["title"] as? String, !title.isEmpty else {
                        throw AgentToolError.missingParameter("title")
                    }
                    var due: Date? = nil
                    if let dueStr = args["dueDate"] as? String {
                        let f = DateFormatter()
                        f.dateFormat = "yyyy-MM-dd HH:mm"
                        due = f.date(from: dueStr)
                    }
                    let hw = HomeworkItem(
                        title: title,
                        courseName: args["courseName"] as? String,
                        dueDate: due
                    )
                    dm.addHomework(hw)
                    return "已添加作业：《\(title)》\(due != nil ? "，截止 \(Self.dateText(due!))" : "")。"
                }
            ),

            // ── 5. 记一笔账 ────────────────────────────────
            AgentTool(
                name: "add_ledger_entry",
                description: "帮用户记一笔消费。用户说'午饭花了15块'这类话时使用。category 必须是：\(AgentToolRegistry.ledgerCategories.joined(separator: "/")) 之一。",
                parametersSchema: [
                    "type": "object",
                    "properties": [
                        "amount": ["type": "number", "description": "金额（元），正数"],
                        "category": ["type": "string", "description": "分类：\(AgentToolRegistry.ledgerCategories.joined(separator: "/"))"],
                        "note": ["type": "string", "description": "备注，如：午饭"]
                    ],
                    "required": ["amount"]
                ],
                execute: { args in
                    let amount = Self.numberValue(args["amount"])
                    guard amount > 0 else { throw AgentToolError.missingParameter("amount") }
                    let category = (args["category"] as? String) ?? "其他"
                    let entry = LedgerEntry(amount: amount, category: category, note: args["note"] as? String)
                    dm.addLedgerEntry(entry)
                    return "已记账：\(category) ¥\(String(format: "%.1f", amount))\(entry.note.map { "（\($0)）" } ?? "")。"
                }
            ),

            // ── 5.5 从短信/文本解析快递并入库 ───────────────
            AgentTool(
                name: "add_parcel_from_sms",
                description: "把用户粘贴的取件短信/通知文本解析出取件码和驿站，自动记入快递列表。用户说'帮我记一下这个快递'并附上短信内容时使用。",
                parametersSchema: [
                    "type": "object",
                    "properties": [
                        "text": ["type": "string", "description": "快递短信/通知的完整原文"]
                    ],
                    "required": ["text"]
                ],
                execute: { args in
                    guard let text = args["text"] as? String, !text.isEmpty else {
                        throw AgentToolError.missingParameter("text")
                    }
                    guard let parsed = ParcelSmsParser.parse(text) else {
                        return "没能从这段文字里识别出取件码（需要类似 3-2-5088 的格式），请用户手动到事务页记录。"
                    }
                    let parcel = ParcelItem(
                        code: parsed.code,
                        station: parsed.station ?? "未识别驿站",
                        note: nil
                    )
                    dm.addParcel(parcel)
                    return "已记入快递：取件码 \(parsed.code)，驿站 \(parsed.station ?? "未识别")。今晚 20:00 会提醒用户取件。"
                }
            ),

            // ── 6. 查本月消费 ──────────────────────────────
            AgentTool(
                name: "get_month_expense",
                description: "查询本月消费总额与各分类占比。用户问'这个月花了多少/钱都花哪了'时使用。",
                parametersSchema: ["type": "object", "properties": [:] as [String: Any]],
                execute: { _ in
                    let cal = Calendar.current
                    let monthEntries = dm.ledgerEntries.filter { cal.isDate($0.date, equalTo: Date(), toGranularity: .month) }
                    guard !monthEntries.isEmpty else { return "本月还没有任何记账记录。" }
                    let total = monthEntries.reduce(0) { $0 + $1.amount }
                    let byCategory = Dictionary(grouping: monthEntries, by: { $0.category })
                        .mapValues { $0.reduce(0) { $0 + $1.amount } }
                        .sorted { $0.value > $1.value }
                    let lines = byCategory.map { cat, sum in
                        "· \(cat)：¥\(String(format: "%.1f", sum))（\(Int(sum / total * 100))%）"
                    }
                    return "本月共消费 ¥\(String(format: "%.1f", total))（\(monthEntries.count) 笔）：\n" + lines.joined(separator: "\n")
                }
            ),

            // ── 7. 查今日步数 ──────────────────────────────
            AgentTool(
                name: "get_step_count",
                description: "查询用户今天的实时步数（CoreMotion）。用户问'今天走了多少步/步数够了吗'时使用。",
                parametersSchema: ["type": "object", "properties": [:] as [String: Any]],
                execute: { _ in
                    // CoreMotion 查询是回调式 API，包一层 async
                    let steps: Int = await withCheckedContinuation { cont in
                        StepCounter.todaySteps { value in
                            cont.resume(returning: value)
                        }
                    }
                    var text = "今天已走 \(steps) 步。"
                    if steps >= 10000 { text += "已达成 10000 步满奖励！" }
                    else if steps >= 6000 { text += "已达 6000 步，再走 \(10000 - steps) 步可拿满奖励。" }
                    else { text += "距离 6000 步目标还差 \(6000 - steps) 步。" }
                    return text
                }
            ),

            // ── 8. 查天气 ──────────────────────────────────
            AgentTool(
                name: "get_weather",
                description: "查询今天的天气与温度（Open-Meteo 数据）。用户问'今天天气怎么样/要不要带伞'时使用。",
                parametersSchema: ["type": "object", "properties": [:] as [String: Any]],
                execute: { _ in
                    let days: [DayWeather] = await withCheckedContinuation { cont in
                        WeatherManager.fetchDailyWeather { value in
                            cont.resume(returning: value)
                        }
                    }
                    guard let today = days.first else {
                        return "天气数据暂时获取失败（可能是定位或网络问题）。"
                    }
                    let f = DateFormatter()
                    f.dateFormat = "M月d日"
                    return "今天（\(f.string(from: today.date))）\(today.description)，气温 \(Int(today.tempMin))~\(Int(today.tempMax))℃\(today.rainy ? "，有降水，建议带伞☂️" : "")。"
                }
            ),
        ]
    }

    // MARK: - 工具执行入口（带兜底：任何异常都变成文本结果回给模型，不中断循环）
    static func run(_ tool: AgentTool, argumentsJSON: String) async -> String {
        do {
            let args = try Self.parseArguments(argumentsJSON)
            return try await tool.execute(args)
        } catch let error as AgentToolError {
            return "工具执行失败：\(error.localizedDescription)"
        } catch {
            return "工具执行失败：\(error.localizedDescription)"
        }
    }

    /// 解析模型给出的参数 JSON（空串/非法 JSON 一律按空参数处理，让工具自行校验必填项）
    static func parseArguments(_ json: String) throws -> [String: Any] {
        guard !json.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let data = json.data(using: .utf8),
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return obj
    }

    /// 当前星期几（1=周一 … 7=周日，与 Course.dayOfWeek 一致）
    static func currentDayOfWeek(now: Date = Date()) -> Int {
        let g = Calendar.current.component(.weekday, from: now)
        return g == 1 ? 7 : g - 1
    }

    static func dateText(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "M月d日 HH:mm"
        return f.string(from: date)
    }

    /// 宽松取数值：模型可能给 15 或 "15" 或 15.5
    static func numberValue(_ any: Any?) -> Double {
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        if let s = any as? String { return Double(s) ?? 0 }
        return 0
    }
}

// MARK: 工具层错误
enum AgentToolError: LocalizedError {
    case missingParameter(String)
    var errorDescription: String? {
        switch self {
        case .missingParameter(let name): return "缺少必需参数：\(name)"
        }
    }
}
