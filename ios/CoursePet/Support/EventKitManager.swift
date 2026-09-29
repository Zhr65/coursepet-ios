// MARK: - 系统日历只读接入（EventKit）
// 设计原则：只读不写——课表/作业是 App 自己的数据源，系统日历只作为 Agent 的补充上下文。
// 未授权时所有查询返回空串（调用方零成本跳过）；只有 Agent 工具调用才主动弹授权窗。
import Foundation
import EventKit

enum EventKitManager {
    static let store = EKEventStore()

    /// 是否已获日历读权限（iOS 17+ fullAccess / iOS 16 旧 API）
    static var isAuthorized: Bool {
        if #available(iOS 17.0, *) {
            return store.authorizationStatus(for: .event) == .fullAccess
        }
        return EKEventStore.authorizationStatus(for: .event) == .authorized
    }

    /// 请求权限（异步回调，主线程返回）
    static func requestAccess(completion: @escaping (Bool) -> Void) {
        if #available(iOS 17.0, *) {
            store.requestFullAccessToEvents { granted, _ in
                DispatchQueue.main.async { completion(granted) }
            }
        } else {
            store.requestAccess(to: .event) { granted, _ in
                DispatchQueue.main.async { completion(granted) }
            }
        }
    }

    /// 拉取 [start, end) 区间日程拼成给 LLM 看的紧凑文本（无日程/无权限返回空串）
    private static func eventsText(from start: Date, to end: Date, limit: Int = 12) -> String {
        guard isAuthorized else { return "" }
        let predicate = store.predicateForEvents(withStart: start, end: end)
        let events = store.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }
            .prefix(limit)
        guard !events.isEmpty else { return "" }
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        let dayF = DateFormatter()
        dayF.dateFormat = "M/d"
        return events.map { e in
            let title = e.title ?? "（无标题）"
            let time = e.isAllDay ? " 全天" : " \(f.string(from: e.startDate))-\(f.string(from: e.endDate))"
            let loc = (e.location?.isEmpty == false) ? " @\(e.location!)" : ""
            let day = Calendar.current.isDateInToday(e.startDate) ? "" : "（\(dayF.string(from: e.startDate))）"
            return "- \(title)\(day)\(time)\(loc)"
        }
        .joined(separator: "\n")
    }

    /// 今天的日程文本（聊天上下文注入用：未授权返回空串，绝不弹窗）
    static func todayEventsText() -> String {
        let cal = Calendar.current
        guard let start = cal.date(bySettingHour: 0, minute: 0, second: 0, of: Date()),
              let end = cal.date(byAdding: .day, value: 1, to: start) else { return "" }
        return eventsText(from: start, to: end)
    }

    /// 带授权请求的查询（Agent 工具用）：未决定时弹授权窗，拒绝返回提示文本
    static func fetchEventsText(range: String, completion: @escaping (String) -> Void) {
        let cal = Calendar.current
        let start: Date
        let end: Date
        if range == "week" {
            start = cal.startOfDay(for: Date())
            end = cal.date(byAdding: .day, value: 7, to: start) ?? start
        } else {
            start = cal.date(bySettingHour: 0, minute: 0, second: 0, of: Date()) ?? Date()
            end = cal.date(byAdding: .day, value: 1, to: start) ?? start
        }
        requestAccess { granted in
            guard granted else {
                completion("没有日历访问权限（用户未授权），无法查询系统日历；建议用户到系统设置里开权限。")
                return
            }
            let text = eventsText(from: start, to: end)
            completion(text.isEmpty ? "这个范围里系统日历没有日程安排。" : text)
        }
    }
}
