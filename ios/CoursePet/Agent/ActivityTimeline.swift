// MARK: - 活动时间线（Muse 式"它今天干了什么"）
// Agent 每次成功的工具调用（记作业/记账/存文件/建任务/查课表…）在这里留痕，
// 用户在形象弹层切到"活动"页签即可回看。Documents JSON 单文件存储，200 条 FIFO。
// 记录点：AgentEngine 工具执行成功后、show_card 出卡后、PetAvatarSheet 改名后。
import Foundation
import SwiftUI

struct ActivityEvent: Codable, Identifiable {
    var id: UUID
    var date: Date
    var icon: String      // SF Symbol 名
    var title: String     // 一句话：干了什么
    var detail: String    // 补充：结果/参数摘要
}

enum ActivityTimelineStore {
    private static let maxEvents = 200
    private static var cache: [ActivityEvent]?

    private static var fileURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("agent_activity.json")
    }

    static func loadAll() -> [ActivityEvent] {
        if let cache { return cache }
        guard let data = try? Data(contentsOf: fileURL),
              let items = try? JSONDecoder().decode([ActivityEvent].self, from: data) else {
            cache = []
            return []
        }
        cache = items
        return items
    }

    /// 最新在前插入，超出上限丢最旧
    static func record(icon: String, title: String, detail: String = "") {
        var events = loadAll()
        events.insert(ActivityEvent(id: UUID(), date: Date(), icon: icon,
                                    title: title, detail: detail), at: 0)
        if events.count > maxEvents { events = Array(events.prefix(maxEvents)) }
        persist(events)
    }

    static func clear() {
        persist([])
    }

    private static func persist(_ events: [ActivityEvent]) {
        cache = events
        if let data = try? JSONEncoder().encode(events) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}

// MARK: - 工具调用 → 活动文案（标题/描述/图标）
enum ActivityLogger {
    /// 写类工具名单（这些必记，一条不合并）；确认卡工具在用户点头后才记（resolveConfirmation）
    private static let writeTools: Set<String> = [
        "add_homework", "add_ledger_entry", "add_parcel_from_sms",
        "create_task", "set_reminder", "add_countdown", "remember_this",
        "save_file", "add_course_material", "generate_image", "modify_schedule",
        "manage_homework", "manage_parcel", "manage_ledger", "manage_memory", "manage_reminder",
    ]

    // 读类聚合：一轮对话里查了课表+天气+步数，合并记一条，避免 200 条被刷穿
    private static var readNames: [String] = []
    private static var readCount = 0

    private static func isWriteTool(_ name: String) -> Bool {
        writeTools.contains(name)
    }

    /// 读类工具聚合记录（引擎最终回答时 flush 成一条）
    static func flushReadSummary() {
        guard readCount > 0 else { return }
        let uniq = Array(Set(readNames)).prefix(3)
        let detail = readCount > uniq.count
            ? "查了 \(readCount) 项：\(uniq.joined(separator: "、"))等"
            : "查了 \(readCount) 项：\(uniq.joined(separator: "、"))"
        ActivityTimelineStore.record(icon: "sparkles", title: "回答了你的问题", detail: detail)
        readNames = []
        readCount = 0
    }

    /// 宽容解析参数 JSON 里的常用字段（拿不到就用空串，绝不让记录动作本身报错）
    private static func args(_ json: String) -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any] else { return [:] }
        return dict
    }

    private static func str(_ dict: [String: Any], _ key: String) -> String? {
        (dict[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 工具执行成功后调用：写类必记；读类只累积，最终回答时 flushReadSummary 合并一条
    static func logToolCall(name: String, argumentsJSON: String, result: String) {
        let a = args(argumentsJSON)
        var icon = "sparkles"
        var title = ""
        var detail = ""

        switch name {
        case "get_today_schedule":
            icon = "calendar"
            title = "翻了翻今天的课表"
        case "get_next_class":
            icon = "clock"
            title = "看了下接下来要上什么课"
        case "get_pending_homeworks":
            icon = "checklist"
            title = "数了数还没做完的作业"
        case "add_homework":
            icon = "square.and.pencil"
            title = "记下了一条作业"
            detail = str(a, "title") ?? ""
        case "add_ledger_entry":
            icon = "yensign.circle"
            title = "记下了一笔账"
            if let amount = a["amount"] as? Double {
                detail = "¥\(String(format: "%.2f", amount)) · \(str(a, "category") ?? "其他")"
            }
        case "add_parcel_from_sms":
            icon = "shippingbox"
            title = "记下了一个快递"
            detail = str(a, "text").map { String($0.prefix(40)) } ?? ""
        case "get_month_expense":
            icon = "chart.pie"
            title = "汇总了这个月的账单"
        case "get_step_count":
            icon = "figure.walk"
            title = "看了看今天的步数"
        case "get_weather":
            icon = "cloud.sun"
            title = "查了查天气"
        case "get_calendar_events":
            icon = "calendar.badge.clock"
            title = "读了读系统日历"
        case "create_task":
            icon = "alarm"
            title = "设好了一个定时任务"
            detail = str(a, "title") ?? ""
        case "set_reminder":
            icon = "alarm"
            title = "设好了一个定时提醒"
            detail = str(a, "title") ?? ""
        case "add_countdown":
            icon = "hourglass"
            title = "建好了一个倒计时"
            detail = str(a, "title") ?? ""
        case "remember_this":
            icon = "brain.head.profile"
            title = "把一件事记进了长期记忆"
            detail = str(a, "content").map { String($0.prefix(40)) } ?? ""
        case "list_tasks":
            icon = "list.bullet"
            title = "翻了翻定时任务清单"
        case "save_file":
            icon = "folder.badge.plus"
            title = "存了一份文件到文件柜"
            detail = str(a, "filename") ?? str(a, "title") ?? ""
        case "read_file":
            icon = "doc.text"
            title = "读了一份文件"
            detail = str(a, "filename") ?? ""
        case "list_files":
            icon = "folder"
            title = "翻了翻文件柜"
        case "add_course_material":
            icon = "books.vertical"
            title = "收进了一份课件笔记"
            detail = str(a, "title") ?? ""
        case "search_course_materials":
            icon = "magnifyingglass"
            title = "在资料库里搜了搜"
            detail = str(a, "query") ?? ""
        case "web_search":
            icon = "globe"
            title = "上网搜了搜"
            detail = str(a, "query") ?? ""
        case "browse_url":
            icon = "safari"
            title = "读了一个网页"
            detail = str(a, "url") ?? ""
        case "list_skills":
            icon = "square.grid.2x2"
            title = "翻了翻自己的技能库"
        case "load_skill":
            icon = "book"
            title = "学了一眼技能手册"
            detail = str(a, "skill") ?? ""
        case "generate_image":
            icon = "paintbrush.pointed"
            title = "画了一张图"
            detail = str(a, "prompt").map { String($0.prefix(40)) } ?? ""
        default:
            // 兜底：未知/新增工具也能留痕，不丢活动
            icon = "sparkles"
            title = "用了「\(name)」工具"
        }

        // 写类直接记；已知读类累积到最终回答时合并一条；未知工具直接留痕兜底
        if isWriteTool(name) {
            // detail 兜底：参数里没摘要时截结果前 50 字（工具结果多为 JSON，至少有信息量）
            if detail.isEmpty {
                let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { detail = String(trimmed.prefix(50)) }
            }
            ActivityTimelineStore.record(icon: icon, title: title, detail: detail)
        } else if let label = readLabel(for: name) {
            readCount += 1
            readNames.append(label)
        } else {
            ActivityTimelineStore.record(icon: icon, title: title,
                   detail: String(result.trimmingCharacters(in: .whitespacesAndNewlines).prefix(50)))
        }
    }

    /// 读类工具的短标签（聚合条 detail 用）
    private static func readLabel(for name: String) -> String? {
        switch name {
        case "get_today_schedule": return "课表"
        case "get_next_class": return "下节课"
        case "get_pending_homeworks": return "作业"
        case "get_month_expense": return "账单"
        case "get_step_count": return "步数"
        case "get_weather": return "天气"
        case "get_calendar_events": return "日历"
        case "list_tasks": return "任务清单"
        case "read_file": return "文件"
        case "list_files": return "文件柜"
        case "search_course_materials": return "资料库"
        case "web_search": return "网络搜索"
        case "browse_url": return "网页"
        case "list_skills": return "技能库"
        case "load_skill": return "技能手册"
        default: return nil
        }
    }

    /// show_card 出卡后调用
    static func logCard(title: String, itemCount: Int) {
        ActivityTimelineStore.record(icon: "menubar.rectangle",
               title: "给你看了「\(title)」卡片",
               detail: "\(itemCount) 条内容")
    }
}

// MARK: - 活动时间线视图（PetAvatarSheet 的"活动"页签，自绘行避免嵌 List）
struct ActivityTimelineList: View {
    @State private var events: [ActivityEvent] = []
    @State private var showClearConfirm = false

    /// 显式空初始化器：private @State 会让合成的成员初始化器变 private，跨文件调用不保险
    init() { }

    /// 分组模型（元组不能当 ForEach 的 id keyPath，用小结构体最稳）
    private struct EventGroup: Identifiable {
        let id: String
        let items: [ActivityEvent]
    }

    var body: some View {
        Group {
            if events.isEmpty {
                VStack(spacing: 8) {
                    Text("🕐").font(.largeTitle)
                    Text("还没有活动记录").font(.footnote).foregroundColor(.secondary)
                    Text("它帮你记作业、记账、存文件之后，都会出现在这里")
                        .font(.caption2).foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(grouped) { group in
                        Text(group.id)
                            .font(.footnote).fontWeight(.semibold)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        ForEach(group.items) { event in
                            row(event)
                        }
                    }
                    // 清空入口（Muse 时间线同样支持清理痕迹）
                    Button {
                        showClearConfirm = true
                    } label: {
                        Text("清空活动记录")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .onAppear { events = ActivityTimelineStore.loadAll() }
        .alert("清空活动记录？", isPresented: $showClearConfirm) {
            Button("清空", role: .destructive) {
                ActivityTimelineStore.clear()
                events = []
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text("它做过的事会全部删除，且无法恢复")
        }
    }

    private func row(_ event: ActivityEvent) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: event.icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(.indigo)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Color.indigo.opacity(0.12)))
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                    .font(.subheadline).fontWeight(.semibold)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                if !event.detail.isEmpty {
                    Text(event.detail)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
                Text(timeText(event.date))
                    .font(.caption2)
                    .foregroundColor(Color(.tertiaryLabel))
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    /// 按 今天/昨天/更早 分组（保持最新在前）
    private var grouped: [EventGroup] {
        let cal = Calendar.current
        var today: [ActivityEvent] = []
        var yesterday: [ActivityEvent] = []
        var earlier: [ActivityEvent] = []
        for e in events {
            if cal.isDateInToday(e.date) { today.append(e) }
            else if cal.isDateInYesterday(e.date) { yesterday.append(e) }
            else { earlier.append(e) }
        }
        var groups: [EventGroup] = []
        if !today.isEmpty { groups.append(EventGroup(id: "今天", items: today)) }
        if !yesterday.isEmpty { groups.append(EventGroup(id: "昨天", items: yesterday)) }
        if !earlier.isEmpty { groups.append(EventGroup(id: "更早", items: earlier)) }
        return groups
    }

    private func timeText(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        if Calendar.current.isDateInToday(date) {
            f.dateFormat = "HH:mm"
        } else {
            f.dateFormat = "M/d HH:mm"
        }
        return f.string(from: date)
    }
}
