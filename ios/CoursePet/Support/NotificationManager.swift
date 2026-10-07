// MARK: - 上课提醒本地通知（仅主 App 使用，扩展 target 不编译本文件）
// 职责：申请通知授权 + 按最新课表数据重建未来 7 天内的课程提醒（提前 15 分钟）
import Foundation
import UserNotifications
import ActivityKit

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

    // MARK: - 专注自动结算通知
    /// 冷启动把被杀掉 App 期间的专注自动入账后告知用户（FocusAutoSettle 调用）。
    /// 注意 identifier 刻意不带 coursepet_ 前缀：refreshAll 回前台会清所有本 App 前缀的
    /// 待发通知，结算通知在冷启动 2 秒后弹，用前缀会被刚跑完的 refreshAll 误删。
    static func scheduleFocusSettleNotice(minutes: Int, exp: Int, leveled: Bool) {
        let content = UNMutableNotificationContent()
        content.title = "⏱️ 专注已自动结算"
        content.body = leveled
            ? "本次专注 \(minutes) 分钟，宠物升了级！+\(exp) EXP +2 🍙"
            : "本次专注 \(minutes) 分钟，+\(exp) EXP +2 🍙，辛苦啦"
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "focusAutoSettle",
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 2, repeats: false))
        UNUserNotificationCenter.current().add(request) { _ in }
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

            // 第四步半：快递取件提醒（不受任何开关限制）：
            // 每个未取件包裹在"今天 20:00"提醒一次（触发时刻已过则不排）；
            // 取件/删除后 refreshAll 重建时自动消失。
            for request in buildParcelRequests(parcels: dataManager.parcels) {
                center.add(request) { _ in }
            }

            // 第五步：天气早安播报（独立开关，异步拉取 7 天预报后按天注册；同一回调里顺带做天气突变检测，零额外请求）
            scheduleWeatherBriefings()

            // 第六步：AI 晨报（独立开关）——有缓存零网络重排，无缓存才打一次服务器
            refreshAIBriefing()

            // 第七步：DDL 前夜 AI 建议（主动管家）——把"明天截止"作业的 level1 文案升级为 LLM 生成的剩余时间分析
            refreshHomeworkAdvice()

            // 第八步：快递到达主动播报（主动管家）——每小时限频轮询实时物流，到驿站立即通知
            checkParcelArrivals()

            // 第九步：端侧定时任务提醒重排（refreshAll 清场会清掉 ondevice_ 前缀，按持久化列表重建）
            OnDeviceTaskStore.rebuildNotifications()

            // 第九步半：倒计时通知重排（同样被 refreshAll 清场清掉 countdown_ 前缀，按列表重建）
            AgentCountdownStore.rebuildNotifications()

            // 第十步：每周学习周报（主动管家）——仅周日触发，当周唯一
            refreshWeeklyBrief()
        }
    }

    // MARK: - 请求构建
    /// 构建未取件包裹的取件提醒（今天 20:00，仅未来时刻；超 3 天的包裹标题带"超时"）
    private static func buildParcelRequests(parcels: [ParcelItem]) -> [UNNotificationRequest] {
        let calendar = Calendar.current
        let now = Date()
        guard let reminderTime = calendar.date(bySettingHour: 20, minute: 0, second: 0, of: now),
              reminderTime > now else { return [] }

        return parcels.filter { $0.pickedAt == nil }.map { parcel -> UNNotificationRequest in
            let days = Int(now.timeIntervalSince(parcel.createdAt) / 86400)
            let content = UNMutableNotificationContent()
            if days >= 3 {
                content.title = "📦 快递已经放 \(days) 天啦！"
                content.body = "取件码 \(parcel.code)（\(parcel.station)）还没取，再不取要被退回啦！"
            } else {
                content.title = "📦 有快递还没取"
                content.body = "取件码 \(parcel.code)，在 \(parcel.station)，顺便把它带回来吧～"
            }
            content.sound = .default
            let trigger = UNCalendarNotificationTrigger(dateMatching: calendar.dateComponents([.year, .month, .day, .hour, .minute], from: reminderTime), repeats: false)
            return UNNotificationRequest(identifier: "\(identifierPrefix)parcel_\(parcel.id)", content: content, trigger: trigger)
        }
    }

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
            checkWeatherShift(days: days)
        }
    }

    // MARK: - 天气突变提醒（主动管家）
    /// 对比今天/明天：降水概率大涨（+40% 且明天 ≥60%）或明显降温（最高温骤降 ≥8°C）
    /// 时立即弹一条提醒。挂在预报回调里零额外请求；每天最多一次（UserDefaults 按日标记）。
    private static func checkWeatherShift(days: [DayWeather]) {
        guard weatherEnabled, days.count >= 2 else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        let dayId = formatter.string(from: Date())
        let doneKey = "weatherShiftDone.\(dayId)"
        guard !StorageLocation.defaults.bool(forKey: doneKey) else { return }
        let today = days[0], tomorrow = days[1]
        var body = ""
        if let p0 = today.precipProb, let p1 = tomorrow.precipProb,
           p1 - p0 >= 40, p1 >= 60 {
            body = "明天降水概率从 \(p0)% 跳到 \(p1)%，雨要来了——出门记得带伞 ☔"
        } else if tomorrow.tempMax - today.tempMax <= -8 {
            body = "明天明显降温：最高温 \(Int(today.tempMax))°C → \(Int(tomorrow.tempMax))°C，多穿一件别感冒 🧣"
        }
        guard !body.isEmpty else { return }
        StorageLocation.defaults.set(true, forKey: doneKey)
        let content = UNMutableNotificationContent()
        content.title = "⛈ 天气突变提醒"
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: "\(identifierPrefix)weather_shift_\(dayId)",
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 3, repeats: false))) { _ in }
    }

    // MARK: - DDL 前夜 AI 建议（主动管家）
    /// 把"明天截止"的作业 level1 通知文案从静态模板升级为服务端 LLM 生成的剩余时间分析。
    /// 缓存键按日存储（hwId → AI 文案），refreshAll 高频重建时只对新增作业打一次网络；
    /// 服务器不可用 / LLM 失败时静默——静态 level1 文案已由 refreshAll 排好，用户侧永远有提醒。
    private static func refreshHomeworkAdvice() {
        guard ddlBombEnabled else { return }
        let server = AgentConfigStore.loadServerConfig()
        guard server.isConfigured else { return }

        let calendar = Calendar.current
        // 只分析"明天截止"的未完成作业（level1 通知恰好在前夜 20:00 触发）
        let targets = DataManager.shared.homeworks.filter { hw in
            !hw.isDone && hw.dueDate.map { calendar.isDateInTomorrow($0) } == true
        }
        guard !targets.isEmpty else { return }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        let dayId = formatter.string(from: Date())
        let cacheKey = "ddlAdvice.\(dayId)"

        Task { @MainActor in
            var cached = StorageLocation.defaults.dictionary(forKey: cacheKey) as? [String: String] ?? [:]
            // 只对缓存里没有的作业请求建议（新增作业场景），已有的直接复用
            let missing = targets.filter { cached[$0.id] == nil }
            if !missing.isEmpty {
                let payload: [[String: Any]] = missing.map { hw in
                    var item: [String: Any] = ["id": hw.id, "title": hw.title]
                    if let course = hw.courseName, !course.isEmpty { item["courseName"] = course }
                    if let due = hw.dueDate {
                        let f = DateFormatter()
                        f.dateFormat = "yyyy-MM-dd HH:mm"
                        item["dueDate"] = f.string(from: due)
                    }
                    return item
                }
                if let advices = try? await AgentRemoteClient.fetchDDLAdvice(
                    baseURL: server.baseURL,
                    username: server.username,
                    password: server.password,
                    homeworks: payload) {
                    for (hwId, advice) in advices where !advice.isEmpty {
                        cached[hwId] = advice
                    }
                    StorageLocation.defaults.set(cached, forKey: cacheKey)
                }
            }
            // 等 refreshAll 的静态重建（含 level1 原始通知）先落盘，再用 AI 文案覆盖 level1
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            rescheduleDDLLevelOne(homeworks: targets, advices: cached)
        }
    }

    /// 用 AI 建议文案重排 level1（前夜 20:00）通知：仅覆盖"触发时刻还没过"的；
    /// 标题区分于静态模板，正文即 LLM 分析（含剩余时间 + 行动建议）。
    private static func rescheduleDDLLevelOne(homeworks: [HomeworkItem], advices: [String: String]) {
        let center = UNUserNotificationCenter.current()
        let calendar = Calendar.current
        for hw in homeworks {
            guard let advice = advices[hw.id], !advice.isEmpty,
                  let due = hw.dueDate else { continue }
            let dueDay = calendar.startOfDay(for: due)
            guard let triggerDate = calendar.date(byAdding: DateComponents(day: -1, hour: 20), to: dueDay),
                  triggerDate.timeIntervalSinceNow > 0 else { continue }
            let identifier = "\(identifierPrefix)hw_\(hw.id)_1"
            center.removePendingNotificationRequests(withIdentifiers: [identifier])
            let content = UNMutableNotificationContent()
            content.title = "🌙 DDL 前夜 · 管家分析"
            content.body = advice
            content.sound = .default
            let trigger = UNTimeIntervalNotificationTrigger(
                timeInterval: triggerDate.timeIntervalSinceNow, repeats: false)
            center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)) { _ in }
        }
    }

    // MARK: - 快递到达主动播报（主动管家）
    /// 每小时限频轮询待取件快递的实时物流（快递100 免 key），已到驿站/派送中立即通知。
    /// 到达标记按包裹持久化（每包裹只播一次）；失败静默——下次 refreshAll 再试。
    private static func checkParcelArrivals() {
        let calendar = Calendar.current
        // 入库 3 天内 + 带单号 + 未取件的包裹，最多查 3 个（控制免费接口压力）
        let targets = DataManager.shared.parcels
            .filter { $0.pickedAt == nil && $0.trackingNumber?.isEmpty == false }
            .filter { calendar.dateComponents([.day], from: $0.createdAt, to: Date()).day ?? 0 < 3 }
            .prefix(3)
        guard !targets.isEmpty else { return }

        // 限频：1 小时内查过就跳过网络轮询（到没到用已持久化的标记判断）
        let lastCheck = StorageLocation.defaults.double(forKey: "parcel.arrivalCheck")
        let shouldPoll = Date().timeIntervalSince1970 - lastCheck >= 3600
        if shouldPoll {
            StorageLocation.defaults.set(Date().timeIntervalSince1970, forKey: "parcel.arrivalCheck")
        }

        Task { @MainActor in
            for parcel in targets {
                let arrivedKey = "parcel.arrived.\(parcel.id)"
                guard !StorageLocation.defaults.bool(forKey: arrivedKey) else { continue }
                guard shouldPoll, let trackingNo = parcel.trackingNumber else { continue }
                guard let status = await ParcelTracker.queryStatus(trackingNo), status.arrived else { continue }
                StorageLocation.defaults.set(true, forKey: arrivedKey)
                let content = UNMutableNotificationContent()
                content.title = "📦 快递到了！"
                var body = "\(status.carrier) \(trackingNo) 已到 \(parcel.station)，取件码 \(parcel.code)"
                if !status.latestEvent.isEmpty {
                    body += "\n最新：\(String(status.latestEvent.prefix(40)))"
                }
                content.body = body
                content.sound = .default
                UNUserNotificationCenter.current().add(UNNotificationRequest(
                    identifier: "\(identifierPrefix)parcel_arrived_\(parcel.id)",
                    content: content,
                    trigger: UNTimeIntervalNotificationTrigger(timeInterval: 2, repeats: false))) { _ in }
            }
        }
    }

    // MARK: - AI 晨报（扩展点：主动关怀）
    /// AI 晨报开关（UserDefaults 独立存储，未设置时默认开启）
    static var aiBriefEnabled: Bool {
        get { StorageLocation.defaults.object(forKey: aiBriefToggleKey) as? Bool ?? true }
        set {
            StorageLocation.defaults.set(newValue, forKey: aiBriefToggleKey)
            if !newValue {
                // 关闭时同步撤掉已排程的晨报，当天的天气模板通知由下次 refreshAll 重建回来
                let f = DateFormatter()
                f.dateFormat = "yyyyMMdd"
                UNUserNotificationCenter.current().removePendingNotificationRequests(
                    withIdentifiers: ["\(identifierPrefix)brief_\(f.string(from: Date()))"])
                StorageLocation.defaults.removeObject(forKey: "brief.content.\(f.string(from: Date()))")
            }
        }
    }
    private static let aiBriefToggleKey = "settings.aiBriefEnabled"

    /// 拉取 AI 晨报并重排当天 07:00 通知。免签名环境无 APNs，
    /// "服务器生成 → 端侧拉取 → 本地通知"是免费账号唯一可行的主动触达链路。
    /// 拉取失败时静默保留天气模板通知——用户侧永远有晨报可看，只是内容降级。
    static func refreshAIBriefing() {
        guard aiBriefEnabled else { return }
        let server = AgentConfigStore.loadServerConfig()
        guard server.isConfigured else { return }

        let idFormatter = DateFormatter()
        idFormatter.dateFormat = "yyyyMMdd"
        let dayId = idFormatter.string(from: Date())
        let contentKey = "brief.content.\(dayId)"  // 当天文案缓存：refreshAll 高频重建时零网络

        Task { @MainActor in
            var brief = StorageLocation.defaults.string(forKey: contentKey) ?? ""
            if brief.isEmpty {
                guard let fetched = try? await AgentRemoteClient.fetchDailyBrief(
                    baseURL: server.baseURL,
                    username: server.username,
                    password: server.password) else { return }
                brief = fetched
                StorageLocation.defaults.set(brief, forKey: contentKey)
            }
            scheduleAIBriefNotification(dayId: dayId, body: brief)
        }
    }

    /// 重排当天晨报：成功后顶掉同一天的天气模板（避免两条早安通知轰炸）
    private static func scheduleAIBriefNotification(dayId: String, body: String) {
        let center = UNUserNotificationCenter.current()
        let calendar = Calendar.current
        guard let morning = calendar.date(bySettingHour: 7, minute: 0, second: 0, of: Date()),
              morning.timeIntervalSinceNow > 0 else { return }  // 已过 07:00 不补发
        center.removePendingNotificationRequests(withIdentifiers: [
            "\(identifierPrefix)brief_\(dayId)",
            "\(identifierPrefix)weather_\(dayId)",
        ])
        let content = UNMutableNotificationContent()
        content.title = "🐾 宠物管家晨报"
        content.body = body
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: morning.timeIntervalSinceNow, repeats: false)
        center.add(UNNotificationRequest(
            identifier: "\(identifierPrefix)brief_\(dayId)",
            content: content, trigger: trigger)) { _ in }
    }

    // MARK: - 每周学习周报（主动管家）
    /// 周报开关（UserDefaults 独立存储，未设置时默认开启）
    static var weeklyBriefEnabled: Bool {
        get { StorageLocation.defaults.object(forKey: weeklyBriefToggleKey) as? Bool ?? true }
        set {
            StorageLocation.defaults.set(newValue, forKey: weeklyBriefToggleKey)
            if !newValue {
                // 关闭时撤掉本周已排程的周报并清缓存，下周重新按新状态生成
                let id = mondayId(startOfWeekMonday())
                UNUserNotificationCenter.current().removePendingNotificationRequests(
                    withIdentifiers: ["\(identifierPrefix)weekly_\(id)"])
                StorageLocation.defaults.removeObject(forKey: "weekly.content.\(id)")
            }
        }
    }
    private static let weeklyBriefToggleKey = "settings.weeklyBriefEnabled"

    /// 本周一 0 点（周日视为仍属当前周：周报覆盖周一到周日）
    private static func startOfWeekMonday(of day: Date = Date()) -> Date {
        let calendar = Calendar.current
        let weekday = calendar.component(.weekday, from: day)  // 1=周日…7=周六
        let backDays = weekday == 1 ? 6 : weekday - 2          // 周日回退 6 天到本周一
        return calendar.startOfDay(for: calendar.date(byAdding: .day, value: -backDays, to: day)!)
    }

    private static func mondayId(_ monday: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd"
        return f.string(from: monday)
    }

    /// 拉取本周学习周报并排程周日 20:00 通知（identifier: coursepet_weekly_{周一日期}）。
    /// 挂在 refreshAll 链：仅周日触发，当周唯一（文案缓存按周一日期存，高频重建零网络零 LLM）；
    /// 与晨报同限制：服务器模式才可用，LLM/网络失败静默——这周没周报，无副作用。
    static func refreshWeeklyBrief() {
        guard weeklyBriefEnabled else { return }
        let calendar = Calendar.current
        guard calendar.component(.weekday, from: Date()) == 1 else { return }  // 只在周日
        let server = AgentConfigStore.loadServerConfig()
        guard server.isConfigured else { return }

        let monday = startOfWeekMonday()
        let dayId = mondayId(monday)
        let contentKey = "weekly.content.\(dayId)"

        Task { @MainActor in
            var brief = StorageLocation.defaults.string(forKey: contentKey) ?? ""
            if brief.isEmpty {
                // 端侧汇总周度统计：账单/作业/课程同步算，步数 CoreMotion 异步后补
                let stats = weeklyStats(monday: monday)
                let steps = await withCheckedContinuation { (cont: CheckedContinuation<Int, Never>) in
                    StepCounter.steps(from: monday, to: Date()) { cont.resume(returning: $0) }
                }
                var full = stats
                full["stepsTotal"] = steps
                let elapsed = max(1, (calendar.dateComponents([.day], from: monday, to: Date()).day ?? 0) + 1)
                full["stepsDailyAvg"] = steps / elapsed
                guard let fetched = try? await AgentRemoteClient.fetchWeeklyBrief(
                    baseURL: server.baseURL,
                    username: server.username,
                    password: server.password,
                    stats: full) else { return }
                brief = fetched
                StorageLocation.defaults.set(brief, forKey: contentKey)
            }
            scheduleWeeklyBriefNotification(mondayId: dayId, body: brief)
        }
    }

    /// 汇总本周统计（步数除外——CoreMotion 异步，由调用方补进字典）
    @MainActor
    private static func weeklyStats(monday: Date) -> [String: Any] {
        let calendar = Calendar.current
        let dm = DataManager.shared
        let weekEnd = calendar.date(byAdding: .day, value: 7, to: monday) ?? Date()

        // 1. 账单：本周消费总额 + 笔数 + 分类 top3
        let weekLedger = dm.ledgerEntries.filter { $0.date >= monday && $0.date < weekEnd }
        let total = weekLedger.reduce(0.0) { $0 + $1.amount }
        var byCategory: [String: (sum: Double, count: Int)] = [:]
        for e in weekLedger {
            let cur = byCategory[e.category] ?? (0, 0)
            byCategory[e.category] = (cur.sum + e.amount, cur.count + 1)
        }
        let tops = byCategory.sorted { $0.value.sum > $1.value.sum }.prefix(3)
            .map { "\($0.key) ¥\(String(format: "%.0f", $0.value.sum))（\($0.value.count) 笔）" }

        // 2. 作业：本周截止的完成率 + 本周实际勾掉的数量
        let dueThisWeek = dm.homeworks.filter { $0.dueDate.map { $0 >= monday && $0 < weekEnd } == true }
        let doneAmongDue = dueThisWeek.filter { $0.isDone }.count
        let completedThisWeek = dm.homeworks.filter {
            $0.completedAt.map { $0 >= monday && $0 < weekEnd } == true
        }.count

        // 3. 课程：本周课表（单双周过滤后）总节数
        var courseCount = 0
        if let week = WeekMath.currentWeekNumber(startDateStr: dm.semesterStartDate) {
            courseCount = ScheduleHelpers.courses(forWeek: week, courses: dm.courses).count
        }

        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return [
            "weekStart": f.string(from: monday),
            "ledgerTotal": total,
            "ledgerCount": weekLedger.count,
            "ledgerTop3": tops,
            "homeworkDue": dueThisWeek.count,
            "homeworkDoneAmongDue": doneAmongDue,
            "homeworkCompletedThisWeek": completedThisWeek,
            "courseCount": courseCount,
        ]
    }

    /// 排程本周周报通知（周日 20:00；已过 20:00 则 3 秒后补发——周报晚到仍有价值）
    private static func scheduleWeeklyBriefNotification(mondayId: String, body: String) {
        let center = UNUserNotificationCenter.current()
        let calendar = Calendar.current
        let identifier = "\(identifierPrefix)weekly_\(mondayId)"
        let interval: TimeInterval
        if let sundayEvening = calendar.date(bySettingHour: 20, minute: 0, second: 0, of: Date()),
           sundayEvening.timeIntervalSinceNow > 0 {
            interval = sundayEvening.timeIntervalSinceNow
        } else {
            interval = 3  // 周日 20:00 后才打开 App：立即补发
        }
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        let content = UNMutableNotificationContent()
        content.title = "📊 本周学习周报"
        content.body = body
        content.sound = .default
        center.add(UNNotificationRequest(
            identifier: identifier, content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false))) { _ in }
    }

    // MARK: - Agent 定时任务结果（Muse 式异步任务）
    /// 未读任务结果数（聊天页铃铛角标数据源；变更时广播通知刷新 UI）
    static var agentTaskUnread: Int {
        get { StorageLocation.defaults.integer(forKey: "agent.taskUnread") }
        set {
            StorageLocation.defaults.set(newValue, forKey: "agent.taskUnread")
            NotificationCenter.default.post(name: .agentTaskUnreadChanged, object: nil)
        }
    }

    /// 拉取服务器定时任务的未读结果 → 逐条本地通知（identifier coursepet_task_{resultId}）。
    /// 已弹过的 resultId 记在 UserDefaults，防止用户没点开任务页时重复拉取重复弹。
    /// 挂载点：scenePhase .active + 聊天页 onAppear（内部 60s 节流）。
    /// ⚠️ 严禁挂 refreshAll 链——会被 DataManager.onStateSaved 高频触发打爆服务器。
    private static var lastTasksFetch = Date.distantPast
    static func refreshAgentTasks() {
        let server = AgentConfigStore.loadServerConfig()
        guard server.isConfigured else { return }
        guard Date().timeIntervalSince(lastTasksFetch) >= 60 else { return }
        lastTasksFetch = Date()
        Task { @MainActor in
            guard let tasks = try? await AgentRemoteClient.fetchAgentTasks(
                baseURL: server.baseURL,
                username: server.username,
                password: server.password) else { return }
            let center = UNUserNotificationCenter.current()
            var notified = Set(StorageLocation.defaults.stringArray(forKey: "agent.taskNotifiedIds") ?? [])
            var totalUnread = 0
            var didNotifyNew = false
            for task in tasks {
                totalUnread += task.unreadCount
                for result in task.results where !result.isRead && !notified.contains(String(result.id)) {
                    let content = UNMutableNotificationContent()
                    content.title = "🤖 任务汇报 · \(task.title)"
                    content.body = result.content
                    content.sound = .default
                    center.add(UNNotificationRequest(
                        identifier: "\(identifierPrefix)task_\(result.id)",
                        content: content,
                        trigger: UNTimeIntervalNotificationTrigger(timeInterval: 2, repeats: false))) { _ in }
                    notified.insert(String(result.id))
                    didNotifyNew = true
                }
            }
            // B 线剧情：有新任务结果时让宠物在岛上"汇报"（服务器结果已落库，App 回前台
            // 拉取后上岛 —— 免费签名无 APNs，这是 Live Activity 内容更新的降级主线）。
            // 课程岛优先（有 updateAgentReply 扩展点），否则专注岛走 updateStory。
            if didNotifyNew,
               let first = tasks.flatMap({ $0.results.filter { !$0.isRead } }).first {
                let line = first.content.components(separatedBy: .newlines).first ?? ""
                let clipped = line.trimmingCharacters(in: .whitespacesAndNewlines).prefix(24)
                if !clipped.isEmpty {
                    if Activity<CourseActivityAttributes>.activities.isEmpty {
                        FocusActivityManager.updateStory(text: String(clipped), petAction: "happy")
                    } else {
                        LiveActivityManager.updateAgentReply(String(clipped))
                    }
                }
            }
            if notified.count > 300 { notified = Set(notified.suffix(300)) }
            StorageLocation.defaults.set(Array(notified), forKey: "agent.taskNotifiedIds")
            agentTaskUnread = totalUnread
        }
    }
}

extension Notification.Name {
    /// Agent 定时任务未读数变化（聊天页铃铛角标刷新）
    static let agentTaskUnreadChanged = Notification.Name("agentTaskUnreadChanged")
}
// MARK: - 通知点击路由 + 前台横幅（UNUserNotificationCenterDelegate）
// 修复：之前全工程没设 delegate —— ① App 在前台时通知被系统吞掉不弹横幅，任务结果通知等于静默丢失；
// ② 点击通知只是冷启动停在原页面。现在按 identifier 前缀映射，post 事件给 ContentView
// 走与 coursepet:// 深链同一套 handleDeepLink 切 tab。
extension Notification.Name {
    static let coursepetOpenNotificationRoute = Notification.Name("coursepet.openNotificationRoute")
}

final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationRouter()

    /// App 在前台时也弹横幅 + 声音（不设 delegate 时前台通知默认被吞）
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    /// 点击通知 → 按 identifier 前缀映射目标页，与 onOpenURL 共用路由语义
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = response.notification.request.identifier
        var host: String? = nil
        if id.hasPrefix("coursepet_hw_") || id.hasPrefix("coursepet_parcel_") {
            host = "todo"        // DDL 轰炸 / 取件提醒 → 事务页
        } else if id.hasPrefix("coursepet_task_") {
            host = "feed"        // 定时任务结果 → 养成页（任务中心在聊天页内，先切到入口所在 tab）
        } else if id.hasPrefix("coursepet_geo_") {
            host = "schedule"    // 位置提醒（下节课信息）→ 课表
        } else if id.hasPrefix("coursepet_focuspause") {
            host = "focus"       // 专注暂停提醒 → 专注页
        } else if id.hasPrefix("coursepet_weather_") || id.hasPrefix("coursepet_brief_")
                    || id.hasPrefix("coursepet_weekly_") {
            host = nil           // 播报类（天气/晨报/周报）内容在通知正文里，不跳页
        } else if id.hasPrefix("coursepet_") {
            host = "schedule"    // 课程提醒 coursepet_{courseId}_{yyyyMMdd} → 课表
        }
        if let host, let url = URL(string: "coursepet://\(host)") {
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .coursepetOpenNotificationRoute, object: nil,
                    userInfo: ["url": url])
            }
        }
        completionHandler()
    }
}
