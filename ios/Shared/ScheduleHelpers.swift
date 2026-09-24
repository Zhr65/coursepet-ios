// MARK: - 课程时间逻辑（对应 prototype/js/schedule.js）
import Foundation

public struct ScheduleHelpers {
    // MARK: - 时间解析
    /// 将 "HH:mm" 转为分钟数，非法返回 nil
    public static func timeToMinutes(_ time: String) -> Int? {
        let trimmed = time.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2, parts[0] <= 23, parts[1] <= 59 else { return nil }
        return parts[0] * 60 + parts[1]
    }

    // MARK: - 周过滤
    /// 过滤出在指定周数有效的课程
    public static func courses(forWeek weekNumber: Int, courses: [Course]) -> [Course] {
        let parity = WeekMath.weekParity(of: weekNumber)
        return courses.filter { course in
            course.startWeek <= weekNumber && course.endWeek >= weekNumber &&
            (course.weekParity == .both || course.weekParity == parity)
        }
    }

    /// 过滤出某天的课程，按开始时间排序
    public static func courses(forDay dayOfWeek: Int, courses: [Course]) -> [Course] {
        return courses.filter { $0.dayOfWeek == dayOfWeek }
            .sorted { timeToMinutes($0.startTime) ?? 0 < timeToMinutes($1.startTime) ?? 0 }
    }

    // MARK: - 当前/下一节课
    /// 返回 {current: Course?, next: (course, startDate)?}
    /// startDate 是 next 课程今天的开始日期（考虑跨午夜）
    public static func currentAndNext(courses: [Course], at now: Date = Date()) -> (current: Course?, next: (course: Course, startDate: Date)?) {
        let calendar = Calendar.current
        let dow: Int = {
            let g = calendar.component(.weekday, from: now)  // 1=周日…7=周六
            return g == 1 ? 7 : g - 1                       // 转为 1=周一…7=周日
        }()
        let curMin = calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)
        let midnight = calendar.startOfDay(for: now)

        var current: Course?
        var next: (course: Course, startDate: Date)?

        for course in courses where course.dayOfWeek == dow {
            guard let s = timeToMinutes(course.startTime), let e = timeToMinutes(course.endTime) else { continue }
            let crossMidnight = e <= s

            // 判断是否在上课中
            if s <= curMin && (crossMidnight || curMin < e) {
                if current == nil || s >= (timeToMinutes(current!.startTime) ?? 0) {
                    current = course
                }
            }

            // 判断下一节
            if curMin < s {
                let nextStart = crossMidnight
                    ? midnight.addingTimeInterval(Double(s + 1440) * 60)   // 跨午夜：次日
                    : midnight.addingTimeInterval(Double(s) * 60)
                if next == nil || s < (timeToMinutes(next!.course.startTime) ?? Int.max) {
                    next = (course, nextStart)
                }
            }
        }
        return (current, next)
    }

    // MARK: - 倒计时文本
    /// 返回 "HH:MM:SS"，已过时间返回 "00:00:00"
    public static func countdownText(to target: Date, from now: Date = Date()) -> String {
        let diff = max(0, Int(target.timeIntervalSince(now)))
        let h = diff / 3600
        let m = (diff % 3600) / 60
        let s = diff % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }
}
