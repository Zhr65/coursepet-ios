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
                    let tracking = ParcelSmsParser.extractTrackingNumber(text)
                    let parcel = ParcelItem(
                        code: parsed.code,
                        station: parsed.station ?? "未识别驿站",
                        note: nil,
                        trackingNumber: tracking
                    )
                    dm.addParcel(parcel)
                    if let tracking {
                        return "已记入快递：取件码 \(parsed.code)，驿站 \(parsed.station ?? "未识别")，单号 \(tracking)。今晚 20:00 会提醒用户取件，之后可以问'我的快递到哪了'查实时物流。"
                    }
                    return "已记入快递：取件码 \(parsed.code)，驿站 \(parsed.station ?? "未识别")。今晚 20:00 会提醒用户取件。"
                }
            ),

            // ── 5.6 查快递实时物流 ──────────────────────────
            AgentTool(
                name: "get_parcel_status",
                description: "查询快递的实时物流状态（快递100 数据）。用户问'我的快递到哪了/物流怎么样'时使用。trackingNumber 不传时自动追踪最近的待取件快递单号。",
                parametersSchema: [
                    "type": "object",
                    "properties": [
                        "trackingNumber": ["type": "string", "description": "快递单号，可选；不传则查最近一条带单号的待取件快递"]
                    ]
                ],
                execute: { args in
                    var tracking = (args["trackingNumber"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
                    if tracking.isEmpty {
                        guard let parcel = dm.parcels.first(where: { $0.pickedAt == nil && $0.trackingNumber != nil }) else {
                            return "当前没有可以追踪的快递单号（取件短信里的单号我没记住）。把单号发给我，或者等下次有新取件短信时让我记快递。"
                        }
                        tracking = parcel.trackingNumber!
                    }
                    return await ParcelTracker.query(tracking)
                }
            ),

            // ── 5.7 课程资料入库（端侧 RAG）─────────────────
            AgentTool(
                name: "add_course_material",
                description: "把用户提供的笔记/知识点/重点内容存入课程资料库，供以后检索。用户说'把这段笔记存到资料库/帮我记一下这个知识点'时使用。title 是资料的简短标题（可用课程名+主题），content 是笔记正文。",
                parametersSchema: [
                    "type": "object",
                    "properties": [
                        "title": ["type": "string", "description": "资料标题，如'高数-泰勒公式要点'"],
                        "content": ["type": "string", "description": "笔记/知识点正文"]
                    ],
                    "required": ["title", "content"]
                ],
                execute: { args in
                    guard let title = args["title"] as? String, !title.isEmpty,
                          let content = args["content"] as? String, !content.isEmpty else {
                        throw AgentToolError.missingParameter("title/content")
                    }
                    let doc = AgentDocStore.add(title: title, content: content)
                    return "已存入资料库（第 \(AgentDocStore.count) 份）：《\(doc.title)》\(content.count) 字。以后可以直接问相关内容，我会帮你检索。"
                }
            ),

            // ── 5.8 课程资料检索（端侧 RAG）─────────────────
            AgentTool(
                name: "search_course_materials",
                description: "在用户的课程资料库里按语义检索笔记/知识点。用户问'泰勒公式重点是什么/我之前存的笔记里有没有…'等涉及已存资料的问题时使用，用户提到'资料库/我存的笔记'时必用。",
                parametersSchema: [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string", "description": "检索关键词或问题"]
                    ],
                    "required": ["query"]
                ],
                execute: { args in
                    guard let query = args["query"] as? String, !query.isEmpty else {
                        throw AgentToolError.missingParameter("query")
                    }
                    let hits = AgentDocStore.search(query: query)
                    guard !hits.isEmpty else {
                        return "资料库里没找到与「\(query)」相关的内容（共 \(AgentDocStore.count) 份资料）。可以让用户先把笔记发给你存进资料库。"
                    }
                    var lines = ["在资料库里找到 \(hits.count) 份相关资料："]
                    for (i, hit) in hits.enumerated() {
                        lines.append("【\(i + 1)】《\(hit.doc.title)》相似度 \(String(format: "%.2f", hit.score))：")
                        lines.append(String(hit.doc.content.prefix(600)))
                    }
                    return lines.joined(separator: "\n")
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

// MARK: - 快递100 免 key 查询客户端（扩展点：快递真追踪）
// 实测结论（2026-09）：query 接口免 key 可用；autonumber 识别接口要 key，
// 故承运商改为"字母前缀映射 + 常见公司依次试探"。接口异常时如实降级提示，
// 绝不编造物流状态。端侧模式专用；服务器模式走 tools.py 同逻辑。
enum ParcelTracker {
    private static let carrierNames: [String: String] = [
        "shunfeng": "顺丰", "zhongtong": "中通", "yuantong": "圆通",
        "yunda": "韵达", "jitu": "极兔", "ems": "邮政EMS", "youzhengguonei": "邮政",
        "jd": "京东", "debangkuaidi": "德邦", "shentong": "申通",
    ]
    private static let guessOrder = ["zhongtong", "yuantong", "yunda", "shunfeng", "ems", "jitu", "shentong"]
    private static let prefixMap: [(String, String)] = [
        ("SF", "shunfeng"), ("JDV", "jd"), ("JD", "jd"), ("JT", "jitu"),
        ("YT", "yuantong"), ("ZTO", "zhongtong"), ("STO", "shentong"),
        ("YD", "yunda"), ("EMS", "ems"), ("DB", "debangkuaidi"),
    ]

    /// 单号 → 候选承运商：字母前缀直判；纯数字走常见公司试探
    private static func candidateCompanies(_ trackingNo: String) -> [String] {
        let upper = trackingNo.upper()
        for (prefix, com) in prefixMap where upper.hasPrefix(prefix) && upper.count > prefix.count {
            return [com]
        }
        return guessOrder
    }

    static func query(_ trackingNo: String) async -> String {
        for com in candidateCompanies(trackingNo) {
            guard let url = URL(string: "https://www.kuaidi100.com/query?type=\(com)&postid=\(trackingNo)") else { continue }
            var request = URLRequest(url: url)
            request.timeoutInterval = 8
            request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
            guard let (data, resp) = try? await URLSession.shared.data(for: request),
                  (resp as? HTTPURLResponse)?.statusCode == 200,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return "物流查询暂时失败（查询通道不稳定），单号 \(trackingNo) 稍后再问一次。"
            }
            guard let events = obj["data"] as? [[String: Any]], let latest = events.first,
                  obj["status"] as? String == "200",
                  !(latest["context"] as? String ?? "").contains("查无结果") else { continue }
            let carrier = carrierNames[com] ?? com
            var lines = ["「\(carrier)」\(trackingNo) 最新动态（\(events.count) 条轨迹）："]
            for event in events.prefix(3) {
                let time = (event["ftime"] as? String) ?? (event["time"] as? String) ?? ""
                let context = event["context"] as? String ?? ""
                lines.append("· \(time) \(context)")
            }
            return lines.joined(separator: "\n")
        }
        return "单号 \(trackingNo) 在常见快递公司都查不到轨迹（可能还没揽收、单号有误，或是不常见的承运商）。等商家发货后再问我一次。"
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
