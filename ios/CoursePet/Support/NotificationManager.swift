// MARK: - 上课提醒本地通知（仅主 App 使用，扩展 target 不编译本文件）
// 职责：申请通知授权 + 按最新课表数据重建未来 7 天内的课程提醒（提前 15 分钟）
import Foundation
import UserNotifications

enum NotificationManager {
    /// 本 App 所有通知 identifier 的统一前缀，用于清理时识别自己的通知
    private static let identifierPrefix = "coursepet_"

    // MARK: - 授权申请
    /// 申请通知授权（横幅 + 声音），结果通过 completion 回调（granted = 是否同意）
    static func requestAuthorization(completion: ((Bool) -> Void)? = nil) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            DispatchQueue.main.async {
                completion?(granted)
            }
        }
    }

    // MARK: - 核心重建逻辑
    /// 按最新数据重建全部课程提醒：
    /// 1. 移除所有本 App 已调度的通知（identifier 以 coursepet_ 开头）
    /// 2. 若提醒开关关闭则到此为止（相当于清空）
    /// 3. 否则对未来 7 天内的每一节课，在「上课时间 - 15 分钟」调度一条本地通知
    /// 全程使用 UNUserNotificationCenter 线程安全 API，可在任意线程调用。
    static func refreshAll() {
        let center = UNUserNotificationCenter.current()
        // 第一步：异步取回当前待决通知，把本 App 前缀的全部清掉
        center.getPendingNotificationRequests { requests in
            let ownIds = requests
                .map { $0.identifier }
                .filter { $0.hasPrefix(identifierPrefix) }
            if !ownIds.isEmpty {
                center.removePendingNotificationRequests(withIdentifiers: ownIds)
            }

            // 第二步：开关关闭时只清空、不再重建
            let dataManager = DataManager.shared
            guard dataManager.reminderEnabled else { return }

            // 第三步：读取课程与学期开始日期，构建新的通知请求
            let courses = dataManager.courses
            let semesterStart = dataManager.semesterStartDate
            guard !courses.isEmpty, !semesterStart.isEmpty else { return }

            let newRequests = buildRequests(courses: courses, semesterStart: semesterStart)
            for request in newRequests {
                // 未授权等情况下 add 会走 error 回调，静默忽略即可
                center.add(request) { _ in }
            }
        }
    }

    // MARK: - 请求构建
    /// 构建未来 7 天内所有课程提醒请求（只包含触发时间晚于当前时刻的）
    private static func buildRequests(courses: [Course], semesterStart: String) -> [UNNotificationRequest] {
        let calendar = Calendar.current
        let now = Date()

        // 日期 / 时间格式化器
        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "yyyyMMdd"
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm"

        var result: [UNNotificationRequest] = []

        for dayOffset in 0..<7 {
            // 目标日期（从今天起的 7 天，含今天）
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: calendar.startOfDay(for: now)) else { continue }

            // 该日是星期几：weekday 1=周日…7=周六 → 转为课程模型 1=周一…7=周日
            let weekday = calendar.component(.weekday, from: day)
            let dayOfWeek = weekday == 1 ? 7 : weekday - 1

            // 该日是学期第几周（开学前返回 nil，直接跳过）
            guard let weekNumber = WeekMath.currentWeekNumber(startDateStr: semesterStart, now: day) else { continue }

            // 该周有效的课程（自动处理 startWeek/endWeek/单双周），再筛选当天上课的
            let weekCourses = ScheduleHelpers.courses(forWeek: weekNumber, courses: courses)
            for course in weekCourses where course.dayOfWeek == dayOfWeek {
                // 当天课程开始时间 = 当天零点 + 开始分钟数
                guard let startMinutes = ScheduleHelpers.timeToMinutes(course.startTime) else { continue }
                guard let classStart = calendar.date(byAdding: .minute, value: startMinutes, to: calendar.startOfDay(for: day)) else { continue }

                // 提前 15 分钟触发；只调度未来时间点
                let triggerDate = classStart.addingTimeInterval(-15 * 60)
                let interval = triggerDate.timeIntervalSince(now)
                guard interval > 0 else { continue }

                // 通知内容
                let content = UNMutableNotificationContent()
                content.title = "📚 即将上课"
                if course.location.isEmpty {
                    content.body = "《\(course.name)》15 分钟后开始（\(timeFormatter.string(from: classStart))）"
                } else {
                    content.body = "《\(course.name)》15 分钟后开始（\(timeFormatter.string(from: classStart))）\n📍 \(course.location)"
                }
                content.sound = .default

                let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
                let identifier = "\(identifierPrefix)\(course.id)_\(dayFormatter.string(from: day))"
                result.append(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
            }
        }
        return result
    }
}
