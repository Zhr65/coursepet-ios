// MARK: - 专注任务 / 专注记录 / 专注设置（数据模型 + App Group 持久化 + 统计查询）
// 存储与 DataManager 同模式：JSON 落盘到 App Group 容器 Documents/，
// 主 App 读写，Widget / Live Activity 扩展可读（本文件主要服务主 App）。
// 注意：本文件被三个 target 各编译一份，FocusPalette 用到 SwiftUI 的 Color，
// 必须 import SwiftUI（不能依赖其他文件的同 module import）。
import Foundation
import SwiftUI

// MARK: - 专注任务
struct FocusTask: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var name: String                    // 任务名，如 "学习" "读书"
    var colorIndex: Int                 // 卡片配色索引（0-5，对应 FocusPalette）
    var isBuiltIn: Bool = false         // 内置任务不可删除（可改名/颜色）
}

// MARK: - 专注记录（一次专注会话）
struct FocusSession: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var taskId: String
    var taskName: String                // 冗余存名字：任务删除后统计仍可显示
    var colorIndex: Int
    var start: Date
    var durationSeconds: Int            // 实际专注秒数（放弃也记录已专注部分）
    var completed: Bool                 // true=坚持到目标结束 / false=中途放弃
}

// MARK: - 专注设置（UserDefaults 存 App Group）
struct FocusSettings: Codable, Equatable {
    var pauseRemindMinutes: Int = 20    // 暂停超过 N 分钟发通知提醒（0=关闭）
    var completionSound: Bool = true    // 结束专注时提示音
}

// MARK: - 卡片配色板（与课表马卡龙区分，专注用更饱和的渐变）
enum FocusPalette {
    static let count = 6
    /// 渐变主色（leading → trailing 由主色加深）
    static func colors(_ index: Int) -> (Color, Color) {
        switch index % count {
        case 0: return (Color(red: 0.45, green: 0.42, blue: 0.92), Color(red: 0.35, green: 0.30, blue: 0.80)) // 紫蓝
        case 1: return (Color(red: 0.99, green: 0.78, blue: 0.24), Color(red: 0.96, green: 0.62, blue: 0.18)) // 黄橙
        case 2: return (Color(red: 0.23, green: 0.68, blue: 0.93), Color(red: 0.16, green: 0.55, blue: 0.86)) // 蓝
        case 3: return (Color(red: 0.24, green: 0.76, blue: 0.55), Color(red: 0.13, green: 0.62, blue: 0.44)) // 绿
        case 4: return (Color(red: 0.94, green: 0.47, blue: 0.62), Color(red: 0.87, green: 0.32, blue: 0.50)) // 粉
        default: return (Color(red: 0.95, green: 0.54, blue: 0.32), Color(red: 0.88, green: 0.40, blue: 0.22)) // 橙
        }
    }
}

// MARK: - 统计区间（饼图 / 卡片切换用）
enum FocusStatsRange: String, CaseIterable {
    case day = "日"
    case week = "周"
    case month = "月"
}

// MARK: - 专注数据仓库
@MainActor
final class FocusStore: ObservableObject {
    static let shared = FocusStore()

    @Published private(set) var tasks: [FocusTask] = []
    @Published private(set) var sessions: [FocusSession] = []
    @Published var settings: FocusSettings = FocusSettings() {
        didSet { saveSettings() }
    }

    private let container: URL?
    private static let tasksFile = "focustasks.json"
    private static let sessionsFile = "focussessions.json"
    private static let settingsKey = "focus.settings.v1"
    /// 记录保留天数（防止 sessions 无限膨胀）
    private static let retentionDays = 90

    private init() {
        container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: DataManager.appGroupID
        )?.appendingPathComponent("Documents", isDirectory: true)
        tasks = load([FocusTask].self, FocusStore.tasksFile) ?? Self.defaultTasks
        sessions = load([FocusSession].self, FocusStore.sessionsFile) ?? []
        if let suite = UserDefaults(suiteName: DataManager.appGroupID),
           let data = suite.data(forKey: FocusStore.settingsKey),
           let s = try? JSONDecoder().decode(FocusSettings.self, from: data) {
            settings = s
        }
    }

    /// 首次使用的内置任务（无目标时长，纯任务名+配色）
    static let defaultTasks: [FocusTask] = [
        FocusTask(name: "学习", colorIndex: 0, isBuiltIn: true),
        FocusTask(name: "读书", colorIndex: 1, isBuiltIn: true)
    ]

    // MARK: 任务增删改
    func addTask(name: String, colorIndex: Int) {
        tasks.append(FocusTask(name: name, colorIndex: colorIndex % FocusPalette.count))
        saveTasks()
    }
    func updateTask(_ task: FocusTask) {
        guard let i = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        tasks[i] = task
        saveTasks()
    }
    func removeTask(_ task: FocusTask) {
        guard !task.isBuiltIn else { return }
        tasks.removeAll { $0.id == task.id }
        saveTasks()
    }

    // MARK: 记录写入
    /// 保存一次专注段落（每次暂停/结束时调用，一天可有多段，累计成今日时长）
    func addSession(_ session: FocusSession) {
        sessions.append(session)
        let cutoff = Calendar.current.date(byAdding: .day, value: -FocusStore.retentionDays, to: Date()) ?? Date()
        sessions.removeAll { $0.start < cutoff }
        saveSessions()
    }

    // MARK: - 统计查询
    /// 今日该任务已专注秒数（跨段累计；日期按自然日切，零点自动"重置"）
    func todaySeconds(for task: FocusTask, now: Date = Date()) -> Int {
        sessions
            .filter { $0.taskId == task.id && Calendar.current.isDate($0.start, inSameDayAs: now) }
            .reduce(0) { $0 + $1.durationSeconds }
    }

    /// 今日总览（今日卡：段数 / 时长分钟 / 最长一段分钟）
    func todaySummary(now: Date = Date()) -> (count: Int, minutes: Int, longestMinutes: Int) {
        let today = sessions.filter { Calendar.current.isDate($0.start, inSameDayAs: now) }
        let secs = today.reduce(0) { $0 + $1.durationSeconds }
        let longest = today.map { $0.durationSeconds }.max() ?? 0
        return (today.count, Int(secs / 60), longest / 60)
    }

    /// 累计总览（累计卡：次数 / 总时长 / 日均时长）
    func totalSummary(now: Date = Date()) -> (count: Int, totalMinutes: Int, dailyAvgMinutes: Int) {
        guard !sessions.isEmpty else { return (0, 0, 0) }
        let secs = sessions.reduce(0) { $0 + $1.durationSeconds }
        // 覆盖天数：从首条记录到今天（至少 1 天）
        let firstDay = Calendar.current.startOfDay(for: sessions.map { $0.start }.min() ?? now)
        let days = max(1, (Int(Calendar.current.dateComponents([.day], from: firstDay, to: now).day ?? 0) + 1))
        return (sessions.count, Int(secs / 60), Int(secs / 60 / days))
    }

    /// 区间内按任务聚合的时长分布（饼图数据源），按时长降序
    func distribution(in range: FocusStatsRange, now: Date = Date()) -> [(name: String, colorIndex: Int, minutes: Int)] {
        let cal = Calendar.current
        let filtered: [FocusSession]
        switch range {
        case .day:
            filtered = sessions.filter { cal.isDate($0.start, inSameDayAs: now) }
        case .week:
            guard let weekStart = cal.dateInterval(of: .weekOfYear, for: now)?.start else { return [] }
            filtered = sessions.filter { $0.start >= weekStart }
        case .month:
            guard let monthStart = cal.dateInterval(of: .month, for: now)?.start else { return [] }
            filtered = sessions.filter { $0.start >= monthStart }
        }
        // 按任务聚合
        var buckets: [String: (secs: Int, color: Int)] = [:]
        for s in filtered {
            buckets[s.taskName, default: (0, s.colorIndex)].secs += s.durationSeconds
        }
        return buckets
            .map { (name: $0.key, colorIndex: $0.value.color, minutes: Int($0.value.secs / 60)) }
            .sorted { $0.minutes > $1.minutes }
    }

    // MARK: - 持久化
    private func saveTasks() {
        save(tasks, FocusStore.tasksFile)
    }
    private func saveSessions() {
        save(sessions, FocusStore.sessionsFile)
    }
    private func saveSettings() {
        guard let suite = UserDefaults(suiteName: DataManager.appGroupID),
              let data = try? JSONEncoder().encode(settings) else { return }
        suite.set(data, forKey: FocusStore.settingsKey)
    }

    private func load<T: Decodable>(_ type: T.Type, _ file: String) -> T? {
        guard let container,
              let data = try? Data(contentsOf: container.appendingPathComponent(file)) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
    private func save<T: Encodable>(_ value: T, _ file: String) {
        guard let container else { return }
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: container.appendingPathComponent(file), options: .atomic)
    }
}
