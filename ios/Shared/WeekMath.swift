// MARK: - 周数计算（与 Web prototype/js/week.js 逻辑完全一致）
// 关键教训：不能用 Calendar.current——用户系统日历若设置为农历，
// calendar.date(from: 2026-08-31) 会按农历解释（农历无 31 号）返回 nil，
// 周数计算全线崩溃并兜底第 1 周。所有日期运算必须强制公历。
import Foundation

struct WeekMath {
    // 注意：Swift 的 Date.timeIntervalSince 返回「秒」，不是毫秒！
    // 这个常量名字叫 "msPerDay" 有误导性——Day 1 写的时候照搬了 JS 版本的毫秒常量，
    // 但 Swift 的 API 返回秒，导致除以 86400000 结果永远 < 1 → Int() 截断为 0 → 永远第 1 周！
    // 修复：直接用 86_400（秒/天）。
    static let secondsPerDay: TimeInterval = 86_400
    /// 公历日历（周数计算专用；时区跟随系统，只锁日历种类）
    static let gregorian = Calendar(identifier: .gregorian)

    /// 将日期归零时分秒
    static func startOfDay(_ date: Date) -> Date {
        return gregorian.startOfDay(for: date)
    }

    /// 格式化日期为 "YYYY-MM-DD"（强制公历，不随系统日历设置漂移）
    static func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = gregorian
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// 解析 "yyyy-MM-dd"：POSIX DateFormatter 优先——完全不受用户系统日历（农历）与地区设置影响；
    /// DateComponents 手工构造只作兜底（2026-10 实测：系统日历为农历时 calendar.date(from:) 会把
    /// 2026-08-31 当农历解释（无 31 号）返回 nil，导致周数永远兜底第 1 周）
    static func parseDate(_ s: String) -> Date? {
        let df = DateFormatter()
        df.calendar = gregorian
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd"
        if let d = df.date(from: s) { return d }
        let parts = s.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return gregorian.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    /// 学期开始日 startDateStr 到 now 是第几周；开学前返回 nil
    static func currentWeekNumber(startDateStr: String, now: Date = Date()) -> Int? {
        guard let start = parseDate(startDateStr) else { return nil }
        // timeIntervalSince 返回秒，除以 86400 得到天数（之前错用毫秒常量，导致永远 < 1 → 0 天 → 第 1 周）
        let diffDays = (startOfDay(now) as NSDate).timeIntervalSince(start) / Self.secondsPerDay
        let days = Int(diffDays)
        guard days >= 0 else { return nil }
        return days / 7 + 1
    }

    /// 单双周判定：奇数→single，偶数→double
    /// 与 JS weekParityOf 对应
    static func weekParity(of week: Int) -> WeekParity {
        return week % 2 == 1 ? .single : .double
    }

    /// 诊断：返回周数计算的中间值明细（诊断行专用，定位"为什么算出第 1 周"）
    static func weekDebugText(startDateStr: String, now: Date = Date()) -> String {
        let parts = startDateStr.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else {
            // 段数不对：打印每个字符的 Unicode 码点，抓隐形字符/全角字符
            let codes = startDateStr.unicodeScalars.prefix(12).map { String(format: "U+%04X", $0.value) }
            return "解析失败(段数\(parts.count)) 字符码:\(codes.joined(separator: ","))"
        }
        guard let start = gregorian.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else {
            return "日期构造失败 parts=\(parts)（曾疑似农历日历所致，现已强制公历）"
        }
        let diffDays = (startOfDay(now) as NSDate).timeIntervalSince(start) / Self.secondsPerDay
        guard diffDays >= 0 else { return "开学前 diff=\(String(format: "%.1f", diffDays))天" }
        let days = Int(diffDays)
        return "parts=\(parts) diff=\(String(format: "%.1f", diffDays))天 实算=\(days / 7 + 1)"
    }
}
