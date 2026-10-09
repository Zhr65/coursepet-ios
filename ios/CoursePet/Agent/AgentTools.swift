// MARK: - Agent 工具注册表（端侧工具层）
// 每个 AgentTool = 给模型看的"说明书"（JSON Schema）+ 本地执行的闭包。
// 设计原则：模型只负责"决定调什么、传什么参数"，所有数据读写都在端侧完成，
// 原始数据不出设备——LLM 拿到的只有工具执行后的摘要文本。
import Foundation
import UserNotifications

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

            // ── 4. 添加作业（确认卡：不直接落库，出卡等用户点头）───
            AgentTool(
                name: "add_homework",
                description: "为用户添加一条作业/待办。用户说'帮我记一下要做XX'时使用。dueDate 格式为 yyyy-MM-dd HH:mm，用户没说截止时间就不传。工具不会直接写入——会先弹一张确认卡给用户，用户点头后自动生效，你只需口头确认内容并提醒用户点一下卡片。",
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
                    var dueLine = ""
                    var due: Date? = nil
                    if let dueStr = args["dueDate"] as? String {
                        let f = DateFormatter()
                        f.dateFormat = "yyyy-MM-dd HH:mm"
                        due = f.date(from: dueStr)
                        dueLine = due != nil ? "截止 \(Self.dateText(due!))" : "截止时间「\(dueStr)」没解析出来，用户确认时可以直接在卡片上看到原样"
                    }
                    var lines = ["内容：《\(title)》"]
                    if let course = args["courseName"] as? String, !course.isEmpty { lines.append("课程：\(course)") }
                    if !dueLine.isEmpty { lines.append(dueLine) }
                    return Self.confirmJSON(action: "add_homework", title: "记一条待办", lines: lines, params: args)
                }
            ),

            // ── 5. 记一笔账（确认卡：不直接落库，出卡等用户点头）───
            AgentTool(
                name: "add_ledger_entry",
                description: "帮用户记一笔消费。用户说'午饭花了15块'这类话时使用。category 必须是：\(AgentToolRegistry.ledgerCategories.joined(separator: "/")) 之一。工具不会直接写入——会先弹一张确认卡给用户，用户点头后自动生效，你只需口头确认金额并提醒用户点一下卡片。",
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
                    var category = (args["category"] as? String) ?? "其他"
                    if !ledgerCategories.contains(category) { category = "其他" }
                    var lines = ["金额：¥\(String(format: "%.1f", amount))", "分类：\(category)"]
                    if let note = args["note"] as? String, !note.isEmpty { lines.append("备注：\(note)") }
                    return Self.confirmJSON(action: "add_ledger", title: "记一笔账", lines: lines, params: args)
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
                            return "待取快递里没有可追踪的单号。可先调 get_parcels 查 App 里记的快递（取件码和驿站不需要单号也能取件）。"
                        }
                        tracking = parcel.trackingNumber!
                    }
                    return await ParcelTracker.query(tracking)
                }
            ),

            // ── 5.65 查 App 内已记录的快递列表 ───────────────
            AgentTool(
                name: "get_parcels",
                description: "查询 App 事务页里已记录的快递列表（取件码、驿站、单号、是否已取）。主人问'我有什么快递/有没有快递/取件码是多少/上次那个快递'时必用本工具——这些数据只在 App 里，禁止凭对话记忆回答。",
                parametersSchema: ["type": "object", "properties": [:] as [String: Any]],
                execute: { _ in
                    guard !dm.parcels.isEmpty else {
                        return "App 里还没有记录任何快递。可以把取件短信原文发来用 add_parcel_from_sms 记录，或让用户到事务页手动记。"
                    }
                    let f = DateFormatter()
                    f.dateFormat = "M月d日 HH:mm"
                    var lines: [String] = []
                    let pending = dm.parcels.filter { $0.pickedAt == nil }
                        .sorted { $0.createdAt > $1.createdAt }
                    if pending.isEmpty {
                        lines.append("没有待取的快递（都已取件）。")
                    } else {
                        lines.append("待取 \(pending.count) 件：")
                        for p in pending {
                            var line = "· 取件码 \(p.code) @\(p.station)"
                            if let note = p.note, !note.isEmpty { line += "（备注：\(note)）" }
                            if let t = p.trackingNumber, !t.isEmpty { line += " · 单号 \(t)" }
                            line += " · \(f.string(from: p.createdAt))记入"
                            lines.append(line)
                        }
                    }
                    let picked = dm.parcels.filter { $0.pickedAt != nil }
                        .sorted { ($0.pickedAt ?? $0.createdAt) > ($1.pickedAt ?? $1.createdAt) }
                        .prefix(3)
                    if !picked.isEmpty {
                        lines.append("最近已取：")
                        for p in picked {
                            let at = p.pickedAt.map { f.string(from: $0) } ?? ""
                            lines.append("· \(p.code) @\(p.station)（\(at)取）")
                        }
                    }
                    return lines.joined(separator: "\n")
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
            // ── 9. 结构化卡片（模式 11：Agent 输出 = UI）─────
            AgentTool(
                name: "show_card",
                description: "把查询结果渲染成一张可点击的卡片插入聊天（homework=作业卡/schedule=课表卡/bill=账单卡/jump=外部服务跳转卡）。刚查完作业列表/今日课表/本月账单后，回答文字前先调本工具，items 从工具结果原样提取，用户点卡片可直达对应页面。cardType=jump：主人让你订酒店/机票、点奶茶外卖、网购时（你不能代下单），platform 传 meituan/eleme/ctrip/dianping/taobao/jd/12306/fliggy/netease/bilibili/amap 之一，query 写要买/搜的东西，items 传 1 条操作提示，summary 写「打开平台自己选品付款」。主人说『打开XX App』（如打开网易云音乐/打开B站/打开高德地图）也用 jump 卡：platform 传对应平台、query 留空、title 写 App 名、items 传 1 条「点击卡片直接打开 App」。不要对问答、闲聊、写操作使用。",
                parametersSchema: [
                    "type": "object",
                    "properties": [
                        "cardType": [
                            "type": "string",
                            "enum": ["homework", "schedule", "bill", "jump"],
                            "description": "卡片类型：homework=作业/DDL 列表卡，schedule=今日课表卡，bill=本月账单卡，jump=外部服务跳转卡"
                        ],
                        "title": ["type": "string", "description": "卡片标题，如：今日课表 / 未完成作业 / 本月账单"],
                        "items": [
                            "type": "array",
                            "description": "卡片条目（从工具结果原样提取，最多 12 条）",
                            "items": [
                                "type": "object",
                                "properties": [
                                    "primary": ["type": "string", "description": "主标题：课程名/作业名/分类名"],
                                    "secondary": ["type": "string", "description": "次要信息：时间/截止时间/金额"],
                                    "tertiary": ["type": "string", "description": "补充信息：教室/关联课程/笔数，可选"]
                                ],
                                "required": ["primary"]
                            ]
                        ],
                        "summary": ["type": "string", "description": "底部汇总行，如：共 3 节课 / 本月共 ¥158.0，可选"],
                        "platform": ["type": "string", "description": "jump 卡必填：meituan/eleme/ctrip/dianping/taobao/jd/12306/fliggy/netease/bilibili/amap 之一"],
                        "query": ["type": "string", "description": "jump 卡：要买/搜的东西，如：奶茶 / 杭州 酒店；只是打开App时留空"]
                    ],
                    "required": ["cardType", "items"]
                ],
                execute: { _ in
                    // 正常情况下 AgentEngine 会在注册表执行前拦截 show_card 渲染卡片；走到这里说明参数不合法
                    "卡片参数不合法：cardType 必须是 homework/schedule/bill/jump，items 至少 1 条（每条含 primary）。"
                }
            ),

            // ── 10. 定时提醒（确认卡：用户点头后才建本地通知）──
            AgentTool(
                name: "set_reminder",
                description: "建一条定时提醒。scheduleKind=daily 每天 runTime（HH:MM）提醒一次；scheduleKind=once 在 runAt（yyyy-MM-dd HH:mm）提醒一次。到点弹本地通知。工具不会直接创建——会先弹确认卡，用户点头后自动生效。",
                parametersSchema: [
                    "type": "object",
                    "properties": [
                        "title": ["type": "string", "description": "提醒内容，如：看今天的课表和未完成作业"],
                        "scheduleKind": ["type": "string", "enum": ["daily", "once"], "description": "daily=每天定时，once=一次性"],
                        "runTime": ["type": "string", "description": "daily 必填：HH:MM，如 08:00"],
                        "runAt": ["type": "string", "description": "once 必填：yyyy-MM-dd HH:mm，如 2026-10-08 20:00"]
                    ],
                    "required": ["title", "scheduleKind"]
                ],
                execute: { args in
                    guard let title = args["title"] as? String, !title.isEmpty else {
                        throw AgentToolError.missingParameter("title")
                    }
                    guard let kind = args["scheduleKind"] as? String else {
                        throw AgentToolError.missingParameter("scheduleKind")
                    }
                    if kind == "daily" {
                        guard let rt = (args["runTime"] as? String)?.trimmingCharacters(in: .whitespaces),
                              !rt.isEmpty else {
                            throw AgentToolError.missingParameter("runTime")
                        }
                        let parts = rt.split(separator: ":").compactMap { Int($0) }
                        guard parts.count == 2, (0...23).contains(parts[0]), (0...59).contains(parts[1]) else {
                            return "执行时刻「\(rt)」没解析出来，格式要像 08:30。请用户给个明确的时刻。"
                        }
                        let normalized = String(format: "%02d:%02d", parts[0], parts[1])
                        var params = args
                        params["runTime"] = normalized
                        return Self.confirmJSON(action: "set_reminder", title: "定时提醒",
                                                lines: ["内容：\(title)", "节奏：每天 \(normalized)"], params: params)
                    }
                    guard kind == "once" else {
                        return "scheduleKind 只支持 daily（每天）或 once（一次性）。"
                    }
                    guard let atStr = (args["runAt"] as? String)?.trimmingCharacters(in: .whitespaces),
                          !atStr.isEmpty else {
                        throw AgentToolError.missingParameter("runAt")
                    }
                    let f = DateFormatter()
                    f.dateFormat = "yyyy-MM-dd HH:mm"
                    guard let at = f.date(from: atStr) else {
                        return "执行时刻「\(atStr)」没解析出来，格式要像 2026-10-08 20:00。"
                    }
                    guard at > Date() else {
                        return "这个时刻已经过了，请用户给一个未来的时间再创建。"
                    }
                    return Self.confirmJSON(action: "set_reminder", title: "定时提醒",
                                            lines: ["内容：\(title)", "时间：\(Self.dateText(at))"], params: args)
                }
            ),

            // ── 10.5 倒计时（确认卡：用户点头后才建）──────────
            AgentTool(
                name: "add_countdown",
                description: "建一个重要日期倒计时（如考研/四六级/考试/生日）。用户说'帮我记个倒计时，6月7号考研'这类话时使用。date 格式 yyyy-MM-dd。生效后目标日早 8 点会弹本地通知（前一天也会提前说一声）。工具不会直接创建——会先弹确认卡，用户点头后自动生效。",
                parametersSchema: [
                    "type": "object",
                    "properties": [
                        "title": ["type": "string", "description": "事件名，如：考研初试"],
                        "date": ["type": "string", "description": "目标日期，格式 yyyy-MM-dd，如 2026-06-07"]
                    ],
                    "required": ["title", "date"]
                ],
                execute: { args in
                    guard let title = args["title"] as? String, !title.isEmpty else {
                        throw AgentToolError.missingParameter("title")
                    }
                    guard let dateStr = args["date"] as? String else {
                        throw AgentToolError.missingParameter("date")
                    }
                    let f = DateFormatter()
                    f.dateFormat = "yyyy-MM-dd"
                    guard let date = f.date(from: dateStr) else {
                        return "日期「\(dateStr)」没解析出来，格式要像 2026-06-07。"
                    }
                    let days = Calendar.current.dateComponents([.day],
                        from: Calendar.current.startOfDay(for: Date()),
                        to: Calendar.current.startOfDay(for: date)).day ?? 0
                    guard days >= 0 else {
                        return "\(Self.dateText(date)) 已经过了，倒计时得是未来的日子。"
                    }
                    return Self.confirmJSON(action: "add_countdown", title: "倒计时",
                                            lines: ["事件：\(title)",
                                                    "日期：\(Self.dateText(date))（还有 \(days) 天）"],
                                            params: args)
                }
            ),

            // ── 10.6 记住这件事（确认卡：用户点头后才写进长期记忆）──
            AgentTool(
                name: "remember_this",
                description: "把一件用户明确要求记住的事写进长期记忆（如'记住我对花生过敏'/'记住我室友叫小林'）。用户说'记住…/帮我记着…'时使用；日常闲聊里值得记的事不用这个，正常聊即可。工具不会直接写入——会先弹确认卡，用户点头后自动生效。",
                parametersSchema: [
                    "type": "object",
                    "properties": [
                        "content": ["type": "string", "description": "要记住的一句话，如：主人对花生过敏"]
                    ],
                    "required": ["content"]
                ],
                execute: { args in
                    guard let content = args["content"] as? String, !content.isEmpty else {
                        throw AgentToolError.missingParameter("content")
                    }
                    return Self.confirmJSON(action: "remember_this", title: "记住这件事",
                                            lines: ["记住：\(content)"], params: args)
                }
            ),

            // ── 10.7 改课表（确认卡：复制某天课程/加课/改课/删课，用户点头后写入本地课表）──
            AgentTool(
                name: "modify_schedule",
                description: "修改用户的课表。op 四选一：copy_day=把某天的全部课程复制到另一天（sourceDay/targetDay）；add_course=添加一门课（name/dayOfWeek/startTime/endTime 必填）；update_course=修改已有课程（name 必填，可只写关键词，同名多门时用 dayOfWeek/startTime 定位，要改的项用 newName/newDay/newStartTime/newEndTime/newTeacher/newLocation/newStartWeek/newEndWeek/newWeekParity 传）；remove_course=删除课程（name 必填，同名多门用 dayOfWeek/startTime 定位）。星期都是 1=周一…7=周日；weekParity：both=每周/single=单周/double=双周。课表是按周循环的周期模型，没有'只改某一周'的概念。用户说'把周一的课复制到周六/帮我加一门课/把高数改到周三/删掉周五的体育课'时使用。工具不会直接改——会先弹确认卡，用户点头后自动生效，你只需口头确认并提醒TA点一下卡片。",
                parametersSchema: [
                    "type": "object",
                    "properties": [
                        "op": ["type": "string", "enum": ["copy_day", "add_course", "update_course", "remove_course"],
                               "description": "操作类型：copy_day=复制某天全部课程到另一天，add_course=加课，update_course=改课，remove_course=删课"],
                        "sourceDay": ["type": "integer", "description": "copy_day 必填：源星期，1=周一…7=周日"],
                        "targetDay": ["type": "integer", "description": "copy_day 必填：目标星期"],
                        "name": ["type": "string", "description": "add/update/remove 必填：课名或关键词，如：高数"],
                        "dayOfWeek": ["type": "integer", "description": "add_course 必填；update/remove 可选定位：星期 1=周一…7=周日"],
                        "startTime": ["type": "string", "description": "add_course 必填，如 10:00；update/remove 可选定位"],
                        "endTime": ["type": "string", "description": "add_course 必填，如 11:40"],
                        "teacher": ["type": "string", "description": "add_course 可选：教师"],
                        "location": ["type": "string", "description": "add_course 可选：教室"],
                        "startWeek": ["type": "integer", "description": "add_course 可选：起始周，默认 1"],
                        "endWeek": ["type": "integer", "description": "add_course 可选：结束周，默认 20"],
                        "weekParity": ["type": "string", "enum": ["both", "single", "double"], "description": "add_course 可选：both=每周/single=单周/double=双周，默认 both"],
                        "newName": ["type": "string", "description": "update_course：新课名"],
                        "newDay": ["type": "integer", "description": "update_course：新星期 1=周一…7=周日"],
                        "newStartTime": ["type": "string", "description": "update_course：新开始时间，如 10:00"],
                        "newEndTime": ["type": "string", "description": "update_course：新结束时间"],
                        "newTeacher": ["type": "string", "description": "update_course：新教师"],
                        "newLocation": ["type": "string", "description": "update_course：新教室"],
                        "newStartWeek": ["type": "integer", "description": "update_course：新起始周"],
                        "newEndWeek": ["type": "integer", "description": "update_course：新结束周"],
                        "newWeekParity": ["type": "string", "enum": ["both", "single", "double"], "description": "update_course：新单双周"]
                    ],
                    "required": ["op"]
                ],
                execute: { args in
                    try ScheduleOps.handle(args, courses: dm.courses)
                }
            ),

            // ── 11. 查定时提醒列表（端侧）────────────────────
            AgentTool(
                name: "list_tasks",
                description: "查看当前已创建的定时提醒任务列表（端侧模式为本地通知提醒）。",
                parametersSchema: ["type": "object", "properties": [:] as [String: Any]],
                execute: { _ in
                    let tasks = OnDeviceTaskStore.load()
                    guard !tasks.isEmpty else {
                        return "还没有任何定时提醒任务。用户想让我定时做事时，用 set_reminder 创建。"
                    }
                    let lines = tasks.map { t -> String in
                        if t.isDaily { return "· 「\(t.title)」每天 \(t.runTime)" }
                        if let at = t.runAt { return "· 「\(t.title)」\(Self.dateText(at))" }
                        return "· 「\(t.title)」一次性"
                    }
                    return "当前定时提醒 \(tasks.count) 个：\n" + lines.joined(separator: "\n")
                }
            ),

            // ── 12. 查系统日历（只读）────────────────────
            AgentTool(
                name: "get_calendar_events",
                description: "查询主人 iPhone 系统日历里的日程（today 默认 / week 本周7天）。用户问'我日历/日程上有什么、今天还有什么安排'且不是问课表时使用。",
                parametersSchema: [
                    "type": "object",
                    "properties": [
                        "range": ["type": "string", "description": "查询范围：today（默认）或 week"]
                    ]
                ],
                execute: { args in
                    let range = (args["range"] as? String) ?? "today"
                    return await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
                        EventKitManager.fetchEventsText(range: range) { cont.resume(returning: $0) }
                    }
                }
            ),
            // ── 13. 生成图片（阿里百炼 qwen-image-3.0 文生图，宠物形象/头像类）──
            AgentTool(
                name: "generate_image",
                description: "生成一张图片（文生图，约需 30-90 秒）。主人说'画一个…/给我画…形象的图/生成一张…'时使用。调用前先把主人的简短想法扩写成一段详细的中文绘画描述（主体+外观+服饰道具+风格+背景构图，40-80 字），直接作为 prompt 传入。图片完成后会自动插入聊天，你只需在最终回答里描述画了什么，不要重复调本工具。",
                parametersSchema: [
                    "type": "object",
                    "properties": [
                        "prompt": ["type": "string", "description": "扩写后的详细中文绘画描述，如：一只圆滚滚的白色小猫宇航员，穿着银色宇航服，头盔映着星光，漂浮在深蓝色星空中，远处有蓝色地球，可爱治愈系插画风格，柔和光线，居中构图"]
                    ],
                    "required": ["prompt"]
                ],
                execute: { args in
                    guard let prompt = (args["prompt"] as? String)?
                        .trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty else {
                        throw AgentToolError.missingParameter("prompt")
                    }
                    // 内部完成 提交→轮询→下载→落盘→暂存；成功后引擎取走图片插入聊天流
                    return try await AgentImageGen.generate(prompt)
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

    /// 写类工具统一出口：不直接执行，打包成确认卡 JSON（引擎识别后渲染成卡片等用户点头）
    static func confirmJSON(action: String, title: String, lines: [String], params: [String: Any]) -> String {
        let payload: [String: Any] = [
            "confirmation": [
                "action": action,
                "title": title,
                "lines": lines,
                "params": params,
            ]
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload),
           let json = String(data: data, encoding: .utf8) {
            return json
        }
        return "确认卡打包失败，请用户到对应页面手动记录。"
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

// MARK: - 端侧定时任务存储（create_task / list_tasks 的端侧实现）
// 免签名环境 App 关闭后无法跑 Agent 循环，端侧任务只做"到点弹本地通知"。
// refreshAll 会清空 coursepet_ 前缀的全部待决通知（含这里的 ondevice_），
// 因此任务列表持久化在 UserDefaults，refreshAll 末尾调 rebuildNotifications() 按列表重排。
enum OnDeviceTaskStore {
    static let identifierPrefix = "coursepet_ondevice_"
    private static let listKey = "agent.ondeviceTasks"

    struct Task {
        let id: String          // 通知 identifier 尾段（UUID，重排时不变防重复弹）
        let title: String
        let isDaily: Bool
        let runTime: String     // daily "HH:MM"；once 为空串
        let runAt: Date?        // once 触发时刻
    }

    static func load() -> [Task] {
        guard let raw = StorageLocation.defaults.array(forKey: listKey) as? [[String: Any]] else { return [] }
        return raw.compactMap { item in
            guard let id = item["id"] as? String,
                  let title = item["title"] as? String,
                  let isDaily = item["isDaily"] as? Bool else { return nil }
            return Task(id: id, title: title, isDaily: isDaily,
                        runTime: item["runTime"] as? String ?? "",
                        runAt: (item["runAt"] as? Double).map { Date(timeIntervalSince1970: $0) })
        }
    }

    static func save(_ tasks: [Task]) {
        let raw: [[String: Any]] = tasks.map { t in
            var item: [String: Any] = ["id": t.id, "title": t.title,
                                       "isDaily": t.isDaily, "runTime": t.runTime]
            if let at = t.runAt { item["runAt"] = at.timeIntervalSince1970 }
            return item
        }
        StorageLocation.defaults.set(raw, forKey: listKey)
    }

    static func add(_ task: Task) {
        var all = load()
        all.append(task)
        // 顺带出清已过期 1 天以上的一次性任务
        let cutoff = Date().addingTimeInterval(-86_400)
        all = all.filter { $0.isDaily || ($0.runAt ?? cutoff) > cutoff }
        save(all)
    }

    /// 按持久化列表重排本地提醒（refreshAll 清场后调用；过期 once 任务自动出清）
    static func rebuildNotifications() {
        let tasks = load().filter { $0.isDaily || ($0.runAt ?? .distantPast) > Date() }
        save(tasks)
        let calendar = Calendar.current
        UNUserNotificationCenter.current().getPendingNotificationRequests { requests in
            let staleIds = requests.map { $0.identifier }.filter { $0.hasPrefix(identifierPrefix) }
            if !staleIds.isEmpty {
                UNUserNotificationCenter.current()
                    .removePendingNotificationRequests(withIdentifiers: staleIds)
            }
            for task in tasks {
                guard let trigger = Self.trigger(for: task, calendar: calendar) else { continue }
                UNUserNotificationCenter.current().add(
                    UNNotificationRequest(identifier: identifierPrefix + task.id,
                                          content: Self.content(for: task),
                                          trigger: trigger)) { _ in }
            }
        }
    }

    private static func content(for task: Task) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "⏰ 定时提醒"
        content.body = "「\(task.title)」\(task.isDaily ? "到点啦，来找宠物管家安排一下吧" : "时间到了")"
        content.sound = .default
        return content
    }

    private static func trigger(for task: Task, calendar: Calendar) -> UNNotificationTrigger? {
        if task.isDaily {
            let parts = task.runTime.split(separator: ":").compactMap { Int($0) }
            guard parts.count == 2 else { return nil }
            return UNCalendarNotificationTrigger(
                dateMatching: DateComponents(hour: parts[0], minute: parts[1]), repeats: true)
        }
        guard let at = task.runAt else { return nil }
        return UNCalendarNotificationTrigger(
            dateMatching: calendar.dateComponents([.year, .month, .day, .hour, .minute], from: at),
            repeats: false)
    }
}

// MARK: - 课表写操作（modify_schedule 工具 + 确认执行，打包与落库共用匹配/解析逻辑）
// 课表是周期模型（星期+周次+单双周），没有"只改某一周"的概念：
// 复制/加课 = 新增周期课（每周都会显示）；改/删按「课名+星期+时间」定位课程。
// 确认后写本地 DataManager，onCoursesChanged 钩子自动把课表重新同步服务器（指纹节流）。
enum ScheduleOps {

    static let dayNames = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]

    // MARK: 宽松解析（模型给的参数格式不稳定）

    /// "10:00"/"10：30"/"10点"/"10点30"/"1030" → "HH:mm"；解析不出返回 nil
    static func normalizeTime(_ raw: String) -> String? {
        let nums = raw.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        let h: Int, m: Int
        switch nums.count {
        case 2:          h = nums[0]; m = nums[1]
        case 1 where nums[0] >= 100: h = nums[0] / 100; m = nums[0] % 100
        case 1:          h = nums[0]; m = 0
        default:         return nil
        }
        guard (0...23).contains(h), (0...59).contains(m) else { return nil }
        return String(format: "%02d:%02d", h, m)
    }

    /// 星期几：1~7 / "周一" / "星期三" / "周日" 都能认（1=周一…7=周日）
    static func dayNumber(_ any: Any?) -> Int? {
        if let i = any as? Int, (1...7).contains(i) { return i }
        if let d = any as? Double, (1...7).contains(Int(d)) { return Int(d) }
        guard let s = (any as? String)?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        if let i = Int(s), (1...7).contains(i) { return i }
        for (i, ch) in ["一", "二", "三", "四", "五", "六", "日", "天"].enumerated() where s.contains(ch) {
            return i >= 6 ? 7 : i + 1
        }
        return nil
    }

    /// 单双周：both/all/每周 → .both；single/单周 → .single；double/双周 → .double；其他 nil
    static func weekParity(_ any: Any?) -> WeekParity? {
        guard let s = (any as? String)?.trimmingCharacters(in: .whitespaces).lowercased(), !s.isEmpty else { return nil }
        if ["both", "all", "每周", "每周上课", "全周"].contains(s) { return .both }
        if ["single", "单周", "单"].contains(s) { return .single }
        if ["double", "双周", "双"].contains(s) { return .double }
        return nil
    }

    /// 宽松取整数（模型可能给 3 或 "3" 或 3.0）
    static func intParam(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let d = any as? Double { return Int(d) }
        if let s = any as? String { return Int(s.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    // MARK: 课程定位与展示

    /// 课名匹配：按序子序列（"高数"能匹配"高等数学(下)"，连续包含是它的特例）
    static func nameMatches(_ courseName: String, _ query: String) -> Bool {
        let b = Array(query.lowercased())
        guard !b.isEmpty else { return false }
        var i = 0
        for ch in courseName.lowercased() where i < b.count {
            if ch == b[i] { i += 1 }
        }
        return i == b.count
    }

    /// 按「课名+星期+时间」定位：candidates=所有同名课；hits=收紧后命中
    static func findCourses(name: String, day: Int?, start: String?, in courses: [Course])
        -> (candidates: [Course], hits: [Course]) {
        let candidates = courses.filter { nameMatches($0.name, name) }
        var pool = candidates
        if let day = day { pool = pool.filter { $0.dayOfWeek == day } }
        if let start = start { pool = pool.filter { $0.startTime == start } }
        return (candidates, pool)
    }

    static func courseLine(_ c: Course) -> String {
        var line = "\(dayNames[c.dayOfWeek - 1]) \(c.startTime)-\(c.endTime) 《\(c.name)》"
        if !c.location.isEmpty { line += " @\(c.location)" }
        if !c.teacher.isEmpty { line += " · \(c.teacher)" }
        return line
    }

    static func timeMinutes(_ hhmm: String) -> Int? { ScheduleHelpers.timeToMinutes(hhmm) }

    // MARK: 工具入口（校验参数 → 打包确认卡，不直接写）

    static func handle(_ args: [String: Any], courses: [Course]) throws -> String {
        guard let op = args["op"] as? String else {
            throw AgentToolError.missingParameter("op（copy_day/add_course/update_course/remove_course 四选一）")
        }
        switch op {
        case "copy_day":     return copyDay(args, courses: courses)
        case "add_course":   return addCourseCard(args)
        case "update_course": return updateCourseCard(args, courses: courses)
        case "remove_course": return removeCourseCard(args, courses: courses)
        default: return "op 只支持 copy_day/add_course/update_course/remove_course。"
        }
    }

    /// 把某天的全部课程复制到另一天（周期课：周次/单双周跟原课一致）
    private static func copyDay(_ args: [String: Any], courses: [Course]) -> String {
        guard let from = dayNumber(args["sourceDay"]), let to = dayNumber(args["targetDay"]) else {
            return "要说清从周几复制到周几（sourceDay/targetDay，1=周一…7=周日）。"
        }
        guard from != to else { return "源和目标都是\(dayNames[from - 1])，不用复制。" }
        let source = courses.filter { $0.dayOfWeek == from }
            .sorted { (timeMinutes($0.startTime) ?? 0) < (timeMinutes($1.startTime) ?? 0) }
        guard !source.isEmpty else { return "\(dayNames[from - 1])没有课，没什么可复制的。" }
        let targetKeys = Set(courses.filter { $0.dayOfWeek == to }.map { "\($0.name)#\($0.startTime)" })
        var lines = ["把\(dayNames[from - 1])的 \(source.count) 门课复制到\(dayNames[to - 1])："]
        var dupes = 0
        for c in source {
            var line = "· \(c.startTime)-\(c.endTime) 《\(c.name)》"
            if !c.location.isEmpty { line += " @\(c.location)" }
            if targetKeys.contains("\(c.name)#\(c.startTime)") {
                line += "（\(dayNames[to - 1])已有一节同名同时段的，点了会重复添加）"
                dupes += 1
            }
            lines.append(line)
        }
        if dupes == source.count {
            return "\(dayNames[to - 1])已经有这些课了（课名和时间都一样），不用重复复制。"
        }
        lines.append("注意：课表按周循环，复制后每周\(dayNames[to - 1])都会显示这几门课。")
        var params = args
        params["sourceDay"] = from
        params["targetDay"] = to
        return AgentToolRegistry.confirmJSON(action: "modify_schedule", title: "复制课程到\(dayNames[to - 1])",
                                             lines: lines, params: params)
    }

    /// 加一门课（卡片上写清周期语义）
    private static func addCourseCard(_ args: [String: Any]) -> String {
        guard let name = (args["name"] as? String)?.trimmingCharacters(in: .whitespaces), !name.isEmpty else {
            return "要加的课叫什么名字？（name 参数）"
        }
        guard let day = dayNumber(args["dayOfWeek"]) else {
            return "要说清这门课周几上（dayOfWeek，1=周一…7=周日）。"
        }
        guard let start = (args["startTime"] as? String).flatMap(normalizeTime),
              let end = (args["endTime"] as? String).flatMap(normalizeTime) else {
            return "上课时间没看懂，要说清开始和结束时间（如 10:00 和 11:40）。"
        }
        guard (timeMinutes(end) ?? 0) > (timeMinutes(start) ?? 0) else {
            return "结束时间（\(end)）比开始时间（\(start)）还早，检查一下？"
        }
        let startWeek = intParam(args["startWeek"]) ?? 1
        let endWeek = intParam(args["endWeek"]) ?? 20
        guard (1...25).contains(startWeek), (1...25).contains(endWeek), startWeek <= endWeek else {
            return "周次范围不合法（要在第 1~25 周内，且起始周不晚于结束周）。"
        }
        let parity = weekParity(args["weekParity"]) ?? .both
        let teacher = (args["teacher"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        let location = (args["location"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        let parityText = parity == .both ? "每周上课" : (parity == .single ? "仅单周" : "仅双周")
        var lines = ["加课：\(dayNames[day - 1]) \(start)-\(end) 《\(name)》"]
        if !teacher.isEmpty { lines.append("老师：\(teacher)") }
        if !location.isEmpty { lines.append("教室：\(location)") }
        lines.append("周次：第\(startWeek)-\(endWeek)周 · \(parityText)")
        lines.append("注意：这是周期课，每周\(dayNames[day - 1])都会显示。")
        var params: [String: Any] = ["op": "add_course", "name": name, "dayOfWeek": day,
                                     "startTime": start, "endTime": end,
                                     "startWeek": startWeek, "endWeek": endWeek,
                                     "weekParity": parity.rawValue]
        if !teacher.isEmpty { params["teacher"] = teacher }
        if !location.isEmpty { params["location"] = location }
        return AgentToolRegistry.confirmJSON(action: "modify_schedule", title: "加一门课",
                                             lines: lines, params: params)
    }

    /// 改一门课（卡片逐项列出 原→新）
    private static func updateCourseCard(_ args: [String: Any], courses: [Course]) -> String {
        guard let name = (args["name"] as? String)?.trimmingCharacters(in: .whitespaces), !name.isEmpty else {
            return "要改哪门课？（name 参数，写课名或关键词）"
        }
        let day = dayNumber(args["dayOfWeek"])
        let start = (args["startTime"] as? String).flatMap(normalizeTime)
        let (candidates, hits) = findCourses(name: name, day: day, start: start, in: courses)
        if candidates.isEmpty { return "课表里没有找到名字带「\(name)」的课。" }
        if hits.isEmpty {
            let list = candidates.prefix(5).map { "· \(courseLine($0))" }.joined(separator: "\n")
            return "名字带「\(name)」的课有 \(candidates.count) 门，要改哪门？用 dayOfWeek（星期）或 startTime（时间）说清：\n\(list)"
        }
        if hits.count > 1 {
            let list = hits.prefix(5).map { "· \(courseLine($0))" }.joined(separator: "\n")
            return "这些课都符合条件，说清要改哪一门（带上课名+星期）：\n\(list)"
        }
        let target = hits[0]
        var changes: [String] = []
        var params: [String: Any] = ["op": "update_course", "name": name,
                                     "dayOfWeek": target.dayOfWeek, "startTime": target.startTime]
        func mark(_ key: String, _ newValue: Any?, _ text: String) {
            params[key] = newValue
            changes.append(text)
        }
        if let v = (args["newName"] as? String)?.trimmingCharacters(in: .whitespaces), !v.isEmpty, v != target.name {
            mark("newName", v, "课名：《\(target.name)》→《\(v)》")
        }
        if let d = dayNumber(args["newDay"]), d != target.dayOfWeek {
            mark("newDay", d, "星期：\(dayNames[target.dayOfWeek - 1])→\(dayNames[d - 1])")
        }
        if let v = (args["newStartTime"] as? String).flatMap(normalizeTime), v != target.startTime {
            mark("newStartTime", v, "开始：\(target.startTime)→\(v)")
        }
        if let v = (args["newEndTime"] as? String).flatMap(normalizeTime), v != target.endTime {
            mark("newEndTime", v, "结束：\(target.endTime)→\(v)")
        }
        if let v = (args["newTeacher"] as? String)?.trimmingCharacters(in: .whitespaces), v != target.teacher {
            mark("newTeacher", v, "老师：\(target.teacher.isEmpty ? "（空）" : target.teacher)→\(v.isEmpty ? "（清空）" : v)")
        }
        if let v = (args["newLocation"] as? String)?.trimmingCharacters(in: .whitespaces), v != target.location {
            mark("newLocation", v, "教室：\(target.location.isEmpty ? "（空）" : target.location)→\(v.isEmpty ? "（清空）" : v)")
        }
        if let v = intParam(args["newStartWeek"]), (1...25).contains(v), v != target.startWeek {
            mark("newStartWeek", v, "起始周：第\(target.startWeek)周→第\(v)周")
        }
        if let v = intParam(args["newEndWeek"]), (1...25).contains(v), v != target.endWeek {
            mark("newEndWeek", v, "结束周：第\(target.endWeek)周→第\(v)周")
        }
        if let p = weekParity(args["newWeekParity"]), p != target.weekParity {
            let old = target.weekParity == .both ? "每周" : (target.weekParity == .single ? "单周" : "双周")
            let new = p == .both ? "每周" : (p == .single ? "单周" : "双周")
            mark("newWeekParity", p.rawValue, "单双周：\(old)→\(new)")
        }
        guard !changes.isEmpty else {
            return "没看出要改什么（要改的项和原值一样，或者没传）。要改的项用 newName/newDay/newStartTime 这类参数传。"
        }
        let finalStart = (params["newStartTime"] as? String) ?? target.startTime
        let finalEnd = (params["newEndTime"] as? String) ?? target.endTime
        if (timeMinutes(finalEnd) ?? 0) <= (timeMinutes(finalStart) ?? 0) {
            return "改完结束时间（\(finalEnd)）不晚于开始时间（\(finalStart)），这个组合不合法。"
        }
        var lines = ["原：\(courseLine(target))"]
        lines += changes.map { "改：\($0)" }
        lines.append("注意：改的是这门课的所有周。")
        return AgentToolRegistry.confirmJSON(action: "modify_schedule", title: "改一门课",
                                             lines: lines, params: params)
    }

    /// 删一门课（先定位，歧义时列出让用户说清）
    private static func removeCourseCard(_ args: [String: Any], courses: [Course]) -> String {
        guard let name = (args["name"] as? String)?.trimmingCharacters(in: .whitespaces), !name.isEmpty else {
            return "要删哪门课？（name 参数，写课名或关键词）"
        }
        let day = dayNumber(args["dayOfWeek"])
        let start = (args["startTime"] as? String).flatMap(normalizeTime)
        let (candidates, hits) = findCourses(name: name, day: day, start: start, in: courses)
        if candidates.isEmpty { return "课表里没有找到名字带「\(name)」的课。" }
        if hits.isEmpty || hits.count > 1 {
            let pool = hits.isEmpty ? candidates : hits
            let list = pool.prefix(5).map { "· \(courseLine($0))" }.joined(separator: "\n")
            return "名字带「\(name)」的课有 \(pool.count) 门，要删哪门？说清课名+星期：\n\(list)"
        }
        let target = hits[0]
        let lines = ["删掉：\(courseLine(target))",
                     "注意：删的是这门课的所有周，删了想找回得手动重新加。"]
        let params: [String: Any] = ["op": "remove_course", "name": name,
                                     "dayOfWeek": target.dayOfWeek, "startTime": target.startTime]
        return AgentToolRegistry.confirmJSON(action: "modify_schedule", title: "删一门课",
                                             lines: lines, params: params)
    }

    // MARK: 确认卡点头后的真正落库（AgentConfirmationExecutor 调用）

    static func executeConfirmation(_ args: [String: Any], dataManager dm: DataManager) -> String {
        switch args["op"] as? String {
        case "copy_day":
            guard let from = dayNumber(args["sourceDay"]), let to = dayNumber(args["targetDay"]), from != to else {
                return "执行失败：复制来源/目标星期不合法，课表没动。"
            }
            let source = dm.courses.filter { $0.dayOfWeek == from }
                .sorted { (timeMinutes($0.startTime) ?? 0) < (timeMinutes($1.startTime) ?? 0) }
            guard !source.isEmpty else { return "执行失败：\(dayNames[from - 1])已经没有课了，课表没动。" }
            let copies = source.map { c in
                Course(name: c.name, teacher: c.teacher, location: c.location,
                       dayOfWeek: to, startTime: c.startTime, endTime: c.endTime,
                       startWeek: c.startWeek, endWeek: c.endWeek, weekParity: c.weekParity)
            }
            dm.appendCourses(copies)
            let names = source.map { "《\($0.name)》" }.joined(separator: "、")
            return "已把\(dayNames[from - 1])的 \(source.count) 门课（\(names)）复制到\(dayNames[to - 1])，每周\(dayNames[to - 1])都会显示。"

        case "add_course":
            guard let name = args["name"] as? String, !name.isEmpty,
                  let day = dayNumber(args["dayOfWeek"]),
                  let start = args["startTime"] as? String,
                  let end = args["endTime"] as? String else {
                return "执行失败：课程信息不全，没加进课表。"
            }
            let course = Course(name: name,
                                teacher: (args["teacher"] as? String) ?? "",
                                location: (args["location"] as? String) ?? "",
                                dayOfWeek: day, startTime: start, endTime: end,
                                startWeek: intParam(args["startWeek"]) ?? 1,
                                endWeek: intParam(args["endWeek"]) ?? 20,
                                weekParity: weekParity(args["weekParity"]) ?? .both)
            dm.addCourse(course)
            return "已在课表加上：\(dayNames[day - 1]) \(start)-\(end) 《\(name)》。"

        case "update_course":
            guard let name = args["name"] as? String, !name.isEmpty else {
                return "执行失败：没有课程名，课表没动。"
            }
            let (_, hits) = findCourses(name: name,
                                        day: dayNumber(args["dayOfWeek"]),
                                        start: args["startTime"] as? String,
                                        in: dm.courses)
            guard hits.count == 1, var target = hits.first else {
                return "执行失败：课表里定位不到这门课（可能刚被改过），课表没动，请重新说一次。"
            }
            var desc = ""
            if let v = args["newName"] as? String, v != target.name { target.name = v; desc += "课名、" }
            if let d = dayNumber(args["newDay"]), d != target.dayOfWeek {
                target.dayOfWeek = d
                target.color = CourseColorPalette.color(forDay: d)
                desc += "星期、"
            }
            if let v = args["newStartTime"] as? String, v != target.startTime { target.startTime = v; desc += "开始时间、" }
            if let v = args["newEndTime"] as? String, v != target.endTime { target.endTime = v; desc += "结束时间、" }
            if let v = args["newTeacher"] as? String, v != target.teacher { target.teacher = v; desc += "老师、" }
            if let v = args["newLocation"] as? String, v != target.location { target.location = v; desc += "教室、" }
            if let v = intParam(args["newStartWeek"]), v != target.startWeek { target.startWeek = v; desc += "起始周、" }
            if let v = intParam(args["newEndWeek"]), v != target.endWeek { target.endWeek = v; desc += "结束周、" }
            if let p = weekParity(args["newWeekParity"]), p != target.weekParity { target.weekParity = p; desc += "单双周、" }
            guard !desc.isEmpty else { return "没有需要改的项（新值与原值一致），课表没动。" }
            if (timeMinutes(target.endTime) ?? 0) <= (timeMinutes(target.startTime) ?? 0) {
                return "执行失败：改完结束时间不晚于开始时间，课表没动。"
            }
            dm.updateCourse(target)
            return "已改好《\(target.name)》：\(desc.dropLast())。"

        case "remove_course":
            guard let name = args["name"] as? String, !name.isEmpty else {
                return "执行失败：没有课程名，课表没动。"
            }
            let (_, hits) = findCourses(name: name,
                                        day: dayNumber(args["dayOfWeek"]),
                                        start: args["startTime"] as? String,
                                        in: dm.courses)
            guard hits.count == 1, let target = hits.first else {
                return "执行失败：课表里定位不到这门课（可能已删过），课表没动。"
            }
            dm.removeCourse(withId: target.id)
            return "已从课表删掉：\(courseLine(target))。"

        default:
            return "执行失败：未知操作，课表没动。"
        }
    }
}

// MARK: - 确认卡执行器（用户点头后真正落库的唯一入口）
// 引擎 resolveConfirmation 调用：按 action 分发写入本地 DataManager / 本地通知 / 端侧记忆。
// 服务器模式的意图卡确认后也走这里（写本地 = 事务页立即可见，服务器库不再重复写）。
@MainActor
enum AgentConfirmationExecutor {

    /// 执行一个已确认的写操作，返回结果描述（写进对话历史当注记；失败返回失败说明）
    static func execute(_ conf: AgentConfirmation, dataManager dm: DataManager) -> String {
        let args = conf.params
        switch conf.action {
        case .addLedger:
            let amount = AgentToolRegistry.numberValue(args["amount"])
            guard amount > 0 else { return "执行失败：金额不合法，这笔没记上。" }
            var category = (args["category"] as? String) ?? "其他"
            if !AgentToolRegistry.ledgerCategories.contains(category) { category = "其他" }
            let entry = LedgerEntry(amount: amount, category: category, note: args["note"] as? String)
            dm.addLedgerEntry(entry)
            return "已记账：\(category) ¥\(String(format: "%.1f", amount))。"

        case .addHomework:
            guard let title = args["title"] as? String, !title.isEmpty else {
                return "执行失败：待办内容为空，这条没记上。"
            }
            var due: Date? = nil
            if let dueStr = args["dueDate"] as? String {
                let f = DateFormatter()
                f.dateFormat = "yyyy-MM-dd HH:mm"
                due = f.date(from: dueStr)
            }
            dm.addHomework(HomeworkItem(title: title,
                                        courseName: args["courseName"] as? String,
                                        dueDate: due))
            return "已添加待办：《\(title)》\(due != nil ? "，截止 \(AgentToolRegistry.dateText(due!))" : "")。"

        case .setReminder:
            guard let title = args["title"] as? String, !title.isEmpty,
                  let kind = args["scheduleKind"] as? String else {
                return "执行失败：提醒参数不全，这条没建上。"
            }
            if kind == "daily" {
                let rt = (args["runTime"] as? String) ?? ""
                let parts = rt.split(separator: ":").compactMap { Int($0) }
                guard parts.count == 2, (0...23).contains(parts[0]), (0...59).contains(parts[1]) else {
                    return "执行失败：提醒时刻不合法，这条没建上。"
                }
                let normalized = String(format: "%02d:%02d", parts[0], parts[1])
                OnDeviceTaskStore.add(OnDeviceTaskStore.Task(
                    id: UUID().uuidString, title: title, isDaily: true,
                    runTime: normalized, runAt: nil))
                OnDeviceTaskStore.rebuildNotifications()
                return "已建好每天 \(normalized) 的提醒「\(title)」。"
            }
            guard let atStr = args["runAt"] as? String else {
                return "执行失败：提醒时间缺失，这条没建上。"
            }
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd HH:mm"
            guard let at = f.date(from: atStr), at > Date() else {
                return "执行失败：提醒时间不合法，这条没建上。"
            }
            OnDeviceTaskStore.add(OnDeviceTaskStore.Task(
                id: UUID().uuidString, title: title, isDaily: false, runTime: "", runAt: at))
            OnDeviceTaskStore.rebuildNotifications()
            return "已建好提醒「\(title)」，\(AgentToolRegistry.dateText(at)) 到点会响。"

        case .addCountdown:
            guard let title = args["title"] as? String, !title.isEmpty,
                  let dateStr = args["date"] as? String else {
                return "执行失败：倒计时参数不全，这条没建上。"
            }
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            guard let date = f.date(from: dateStr) else {
                return "执行失败：倒计时日期不合法，这条没建上。"
            }
            let days = AgentCountdownStore.add(title: title, date: date)
            return "已建好倒计时「\(title)」（\(AgentToolRegistry.dateText(date))，还有 \(max(0, days)) 天）。"

        case .rememberThis:
            guard let content = args["content"] as? String, !content.isEmpty else {
                return "执行失败：内容为空，没记住。"
            }
            AgentMemoryStore.addManual(content)
            return "已把「\(content)」记进长期记忆。"

        case .modifySchedule:
            return ScheduleOps.executeConfirmation(args, dataManager: dm)
        }
    }
}

// MARK: - 倒计时存储（add_countdown 的端侧实现，套路与 OnDeviceTaskStore 相同）
// UserDefaults 持久化 + 本地通知：目标日前一天早 8 点提前说一声，当天早 8 点再提一次。
// refreshAll 清场会清掉 coursepet_ 前缀通知，故重排函数同样挂 refreshAll 链。
enum AgentCountdownStore {
    static let identifierPrefix = "coursepet_countdown_"
    private static let listKey = "agent.countdowns"

    struct Countdown: Codable {
        let id: String
        let title: String
        let date: Date      // 目标日（取当天 00:00 语义）
    }

    static func load() -> [Countdown] {
        guard let data = StorageLocation.defaults.data(forKey: listKey),
              let items = try? JSONDecoder().decode([Countdown].self, from: data) else { return [] }
        return items
    }

    private static func save(_ items: [Countdown]) {
        if let data = try? JSONEncoder().encode(items) {
            StorageLocation.defaults.set(data, forKey: listKey)
        }
    }

    /// 新增一条，返回距离目标日的天数（写入成功后立即重排通知）
    static func add(title: String, date: Date) -> Int {
        var all = load().filter {
            // 出清已过期 3 天以上的旧倒计时
            $0.date >= Calendar.current.startOfDay(for: Date()).addingTimeInterval(-3 * 86_400)
        }
        all.append(Countdown(id: UUID().uuidString, title: title, date: date))
        save(all)
        rebuildNotifications()
        return Calendar.current.dateComponents([.day],
            from: Calendar.current.startOfDay(for: Date()),
            to: Calendar.current.startOfDay(for: date)).day ?? 0
    }

    /// 按持久化列表重排通知（refreshAll 清场后调用；过期倒计时自动出清）
    static func rebuildNotifications() {
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { requests in
            let stale = requests.map { $0.identifier }.filter { $0.hasPrefix(identifierPrefix) }
            if !stale.isEmpty {
                center.removePendingNotificationRequests(withIdentifiers: stale)
            }
            let today = Calendar.current.startOfDay(for: Date())
            for item in load() where item.date >= today {
                let cal = Calendar.current
                // 前一天 08:00 提前提醒（当天就是目标日则只有当天一条，不重复打扰）
                if let eve = cal.date(byAdding: .day, value: -1, to: item.date), eve >= today {
                    var comps = cal.dateComponents([.year, .month, .day], from: eve)
                    comps.hour = 8
                    let content = UNMutableNotificationContent()
                    content.title = "⏳ 倒计时"
                    content.body = "明天就是「\(item.title)」啦，准备得怎么样？"
                    content.sound = .default
                    center.add(UNNotificationRequest(
                        identifier: identifierPrefix + item.id + "_eve",
                        content: content,
                        trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false))) { _ in }
                }
                var comps = cal.dateComponents([.year, .month, .day], from: item.date)
                comps.hour = 8
                let content = UNMutableNotificationContent()
                content.title = "⏳ 就是今天"
                content.body = "今天就是「\(item.title)」！稳住，正常发挥就好。"
                content.sound = .default
                center.add(UNNotificationRequest(
                    identifier: identifierPrefix + item.id + "_day",
                    content: content,
                    trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false))) { _ in }
            }
        }
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
        let upper = trackingNo.uppercased()
        for (prefix, com) in prefixMap where upper.hasPrefix(prefix) && upper.count > prefix.count {
            return [com]
        }
        return guessOrder
    }

    // MARK: 结构化查询（主动管家"快递到了主动说"的数据源）
    struct ParcelTrackStatus {
        let carrier: String
        let trackingNo: String
        let arrived: Bool                                  // 已到驿站/派送中/已签收
        let latestEvent: String                            // 最新一条轨迹（播报文案用）
        let events: [(time: String, context: String)]      // 最新在前，最多 3 条
        let totalCount: Int
    }

    enum ParcelTrackOutcome {
        case status(ParcelTrackStatus)
        case noTrace        // 所有候选公司都查无轨迹（未揽收/单号有误/小众承运商）
        case networkError   // 查询通道不稳定
    }

    /// 查询核心：逐个候选公司试到有轨迹为止（工具文本与到达检测共用一份实现）
    private static func fetch(_ trackingNo: String) async -> ParcelTrackOutcome {
        for com in candidateCompanies(trackingNo) {
            guard let url = URL(string: "https://www.kuaidi100.com/query?type=\(com)&postid=\(trackingNo)") else { continue }
            var request = URLRequest(url: url)
            request.timeoutInterval = 8
            request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
            guard let (data, resp) = try? await URLSession.shared.data(for: request),
                  (resp as? HTTPURLResponse)?.statusCode == 200,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .networkError
            }
            guard let events = obj["data"] as? [[String: Any]], let latest = events.first,
                  obj["status"] as? String == "200",
                  !(latest["context"] as? String ?? "").contains("查无结果") else { continue }
            let latestContext = latest["context"] as? String ?? ""
            // 到达判定：快递100 state=3 已签收 / state=5 派件中，或最新轨迹含驿站到件关键词
            let state = obj["state"] as? String ?? ""
            let arrived = state == "3" || state == "5"
                || ["待取", "驿站", "货架", "存放", "代收", "签收", "已到达"].contains(where: { latestContext.contains($0) })
            let top3 = events.prefix(3).map { event -> (time: String, context: String) in
                ((event["ftime"] as? String) ?? (event["time"] as? String) ?? "",
                 event["context"] as? String ?? "")
            }
            return .status(ParcelTrackStatus(
                carrier: carrierNames[com] ?? com,
                trackingNo: trackingNo,
                arrived: arrived,
                latestEvent: latestContext,
                events: top3,
                totalCount: events.count))
        }
        return .noTrace
    }

    /// 到达检测专用：供主动管家轮询，任何失败返回 nil（静默跳过）
    static func queryStatus(_ trackingNo: String) async -> ParcelTrackStatus? {
        if case .status(let s) = await fetch(trackingNo) { return s }
        return nil
    }

    /// 工具用文本摘要（保持原话术：绝不编造物流状态，异常如实降级）
    static func query(_ trackingNo: String) async -> String {
        switch await fetch(trackingNo) {
        case .status(let s):
            var lines = ["「\(s.carrier)」\(trackingNo) 最新动态（\(s.totalCount) 条轨迹）："]
            for event in s.events {
                lines.append("· \(event.time) \(event.context)")
            }
            return lines.joined(separator: "\n")
        case .networkError:
            return "物流查询暂时失败（查询通道不稳定），单号 \(trackingNo) 稍后再问一次。"
        case .noTrace:
            return "单号 \(trackingNo) 在常见快递公司都查不到轨迹（可能还没揽收、单号有误，或是不常见的承运商）。等商家发货后再问我一次。"
        }
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
