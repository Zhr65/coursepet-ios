// MARK: - 上课提醒本地通知（仅主 App 使用，扩展 target 不编译本文件）
// 职责：申请通知授权 + 按最新课表数据重建未来 7 天内的课程提醒（提前 15 分钟）
import Foundation
import UserNotifications

enum NotificationManager {
    /// 本 App 所有通知 identifier 的统一前缀，用于清理时识别自己的通知
    private static let identifierPrefix = "coursepet_"
    /// 专注暂停提醒的通知 identifier（独立前缀，不参与 refreshAll 的课程提醒重建清理）
    private static let pauseReminderId = "coursepet_focuspause"

    // MARK: - 专注暂停提醒
    /// 暂停 N 分钟后发一条本地通知，提醒回来继续专注（0 或负数 = 不提醒）
    static func schedulePauseReminder(afterMinutes: Int, taskName: String) {
        guard afterMinutes > 0 else { return }
        let content = UNMutableNotificationContent()
        content.title = "休息得差不多啦 🍅"
        content.body = "「\(taskName)」已经暂停 \(afterMinutes) 分钟，回来继续专注吧！"
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: TimeInterval(afterMinutes * 60), repeats: false)
        let request = UNNotificationRequest(identifier: pauseReminderId, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request) { _ in }
    }

    /// 恢复专注 / 结束专注时取消暂停提醒
    static func cancelPauseReminder() {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [pauseReminderId])
    }

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
    /// 按最新数据重建全部本地通知：
    /// 1. 移除所有本 App 已调度的通知（identifier 以 coursepet_ 开头）
    /// 2. 课程提醒：跟随「上课提醒」开关，对未来 7 天内每节课在「上课时间 - 15 分钟」调度一条
    /// 3. 作业 DDL 三级轰炸 / 天气早安播报：各有独立开关
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

            // 第二步：读取共享数据（课程提醒受 reminderEnabled 开关控制，
            // DDL 轰炸与天气播报有各自独立开关，不受主开关影响）
            let dataManager = DataManager.shared
            // 第三步：课程提醒——跟随「上课提醒」开关（无课程则跳过）
            let courses = dataManager.courses
            let semesterStart = dataManager.semesterStartDate
            if dataManager.reminderEnabled, !courses.isEmpty, !semesterStart.isEmpty {
                let newRequests = buildRequests(courses: courses, semesterStart: semesterStart)
                for request in newRequests {
                    // 未授权等情况下 add 会走 error 回调，静默忽略即可
                    center.add(request) { _ in }
                }
            }

            // 第四步：作业 DDL 三级轰炸（独立开关）
            if ddlBombEnabled {
                for request in buildHomeworkRequests(homeworks: dataManager.homeworks) {
                    center.add(request) { _ in }
                }
            }

            // 第五步：天气早安播报（独立开关，异步拉取 7 天预报后按天注册）
            scheduleWeatherBriefings()
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

    // MARK: - 作业 DDL 三级轰炸
    /// 每个未完成 + 设置了截止日的作业注册三级提醒：
    /// level 1 = 截止前一天 20:00 / level 2 = 截止当天 08:00 / level 3 = 截止当天 18:00
    /// 只注册触发时刻仍在未来的通知；identifier 形如 coursepet_hw_{id}_{level}
    private static func buildHomeworkRequests(homeworks: [HomeworkItem]) -> [UNNotificationRequest] {
        let calendar = Calendar.current
        let now = Date()
        var result: [UNNotificationRequest] = []

        for hw in homeworks where !hw.isDone {
            guard let due = hw.dueDate else { continue }
            let dueDay = calendar.startOfDay(for: due)
            // 展示名：关联了课程时带上课程名前缀
            let display = (hw.courseName?.isEmpty == false) ? "《\(hw.courseName!)》\(hw.title)" : hw.title

            // (触发时刻, 级别, 通知标题, 正文)
            let levels: [(date: Date, level: String, title: String, body: String)] = [
                (calendar.date(byAdding: DateComponents(day: -1, hour: 20), to: dueDay) ?? dueDay,
                 "1", "⏰ DDL 预警", "「\(display)」明天截止，抓紧安排！"),
                (calendar.date(byAdding: DateComponents(hour: 8), to: dueDay) ?? dueDay,
                 "2", "🔥 今天截止", "「\(display)」今天就是截止日，别忘了交！"),
                (calendar.date(byAdding: DateComponents(hour: 18), to: dueDay) ?? dueDay,
                 "3", "🚨 最后提醒", "「\(display)」今晚就截止了，冲一波！"),
            ]
            for item in levels {
                let interval = item.date.timeIntervalSince(now)
                guard interval > 0 else { continue }   // 已过去的时刻不注册
                let content = UNMutableNotificationContent()
                content.title = item.title
                content.body = item.body
                content.sound = .default
                let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
                result.append(UNNotificationRequest(
                    identifier: "\(identifierPrefix)hw_\(hw.id)_\(item.level)",
                    content: content, trigger: trigger))
            }
        }
        return result
    }

    // MARK: - 通知开关
    /// DDL 轰炸开关（UserDefaults 独立存储，未设置时默认开启）
    static var ddlBombEnabled: Bool {
        get { StorageLocation.defaults.object(forKey: ddlBombToggleKey) as? Bool ?? true }
        set { StorageLocation.defaults.set(newValue, forKey: ddlBombToggleKey) }
    }
    private static let ddlBombToggleKey = "settings.ddlBombEnabled"

    /// 天气播报开关（UserDefaults 独立存储，未设置时默认开启）
    static var weatherEnabled: Bool {
        get { StorageLocation.defaults.object(forKey: weatherToggleKey) as? Bool ?? true }
        set { StorageLocation.defaults.set(newValue, forKey: weatherToggleKey) }
    }
    private static let weatherToggleKey = "settings.weatherEnabled"

    /// 拉取 7 天预报，为每天注册一条 07:00 的早安天气通知（identifier: coursepet_weather_{yyyyMMdd}）
    /// 定位失败 / 网络失败时回调空数组，静默不注册；异步回调在主线程执行 add，线程安全。
    private static func scheduleWeatherBriefings() {
        guard weatherEnabled else { return }
        WeatherManager.fetchDailyWeather { days in
            let center = UNUserNotificationCenter.current()
            let calendar = Calendar.current
            let idFormatter = DateFormatter()
            idFormatter.dateFormat = "yyyyMMdd"
            for day in days {
                // 触发时刻 = 当天早上 07:00，只注册未来的
                guard let morning = calendar.date(bySettingHour: 7, minute: 0, second: 0, of: day.date),
                      morning.timeIntervalSinceNow > 0 else { continue }
                let content = UNMutableNotificationContent()
                content.title = "🌤 早安，今天天气"
                var body = "\(day.description) \(Int(day.tempMin))~\(Int(day.tempMax))°C"
                if day.rainy { body += "，出门记得带伞 ☔" }
                content.body = body
                content.sound = .default
                let trigger = UNTimeIntervalNotificationTrigger(
                    timeInterval: morning.timeIntervalSinceNow, repeats: false)
                center.add(UNNotificationRequest(
                    identifier: "\(identifierPrefix)weather_\(idFormatter.string(from: day.date))",
                    content: content, trigger: trigger)) { _ in }
            }
        }
    }
}
