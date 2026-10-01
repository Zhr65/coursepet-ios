// MARK: - 周数计算（与 Web prototype/js/week.js 逻辑完全一致）
// 关键教训：不能用 Calendar.current——用户系统日历若设置为农历，
// calendar.date(from: 2026-08-31) 会按农历解释（农历无 31 号）返回 nil，
// 周数计算全线崩溃并兜底第 1 周。所有日期运算必须强制公历。
import Foundation

struct WeekMath {
    static let msPerDay: Int = 86_400_000
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

    /// 学期开始日 startDateStr 到 now 是第几周；开学前返回 nil
    /// 与 JS: Math.floor((startOfDay(now) - start) / MS_PER_DAY) + 1 对应
    static func currentWeekNumber(startDateStr: String, now: Date = Date()) -> Int? {
        let parts = startDateStr.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        guard let start = gregorian.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else {
            return nil
        }
        let diffDays = (startOfDay(now) as NSDate).timeIntervalSince(start) / Double(msPerDay)
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
        let diffDays = (startOfDay(now) as NSDate).timeIntervalSince(start) / Double(msPerDay)
        guard diffDays >= 0 else { return "开学前 diff=\(String(format: "%.1f", diffDays))天" }
        let days = Int(diffDays)
        return "parts=\(parts) diff=\(String(format: "%.1f", diffDays))天 实算=\(days / 7 + 1)"
    }
}
