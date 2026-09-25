// MARK: - 周数计算（与 Web prototype/js/week.js 逻辑完全一致）
import Foundation

struct WeekMath {
    static let msPerDay: Int = 86_400_000

    /// 将日期归零时分秒
    static func startOfDay(_ date: Date) -> Date {
        return Calendar.current.startOfDay(for: date)
    }

    /// 格式化日期为 "YYYY-MM-DD"
    static func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// 学期开始日 startDateStr 到 now 是第几周；开学前返回 nil
    /// 与 JS: Math.floor((startOfDay(now) - start) / MS_PER_DAY) + 1 对应
    static func currentWeekNumber(startDateStr: String, now: Date = Date()) -> Int? {
        let parts = startDateStr.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        let calendar = Calendar.current
        guard let start = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else {
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
}
