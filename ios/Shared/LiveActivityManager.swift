// MARK: - Live Activity 启动管理器
// 负责在课前 15 分钟自动启动 Live Activity
import ActivityKit
import SwiftUI
import Foundation

enum LiveActivityManager {
    /// 检查是否有课程将在 15 分钟内开始，如有则启动 Live Activity
    static func checkAndStartIfNeeded() {
        let enabled = ActivityAuthorizationInfo().areActivitiesEnabled
        LADebug.log("检查课程岛：系统实时活动授权=\(enabled)")
        // 注意：授权开启（true）才继续；此前写成 !areActivitiesEnabled 导致已授权反而被拦截，永远不上岛
        guard enabled else {
            LADebug.log("拦截：未授权实时活动（去 系统设置→CoursePet→实时活动 开启）")
            return
        }

        let dataManager = DataManager.shared
        let state = dataManager.loadState()
        // 读内存镜像而非 UserDefaults：主 App 进程里 @Published 永远是最准的
        //（与 NotificationManager 数据源一致）；getSemesterStartDate 是给扩展进程用的
        let semesterStart = dataManager.semesterStartDate
        guard !semesterStart.isEmpty else {
            LADebug.log("拦截：开学日期未设置 → 去 设置→基础 选择开学日期后即可上岛")
            return
        }

        let weekNum = WeekMath.currentWeekNumber(startDateStr: semesterStart) ?? 1
        let weekCourses = ScheduleHelpers.courses(forWeek: weekNum, courses: state.courses)
        LADebug.log("学期第\(weekNum)周，本周课程 \(weekCourses.count) 门")
        let result = ScheduleHelpers.currentAndNext(courses: weekCourses, at: Date())

        // 如果有下节课且在 15 分钟内，启动 Live Activity
        if let next = result.next {
            let minutesUntil = next.startDate.timeIntervalSince(Date()) / 60
            if minutesUntil <= 15 && minutesUntil > 0 {
                LADebug.log(String(format: "命中课前窗口：%@ 还有 %.1f 分钟", next.course.name, minutesUntil))
                startLiveActivity(for: next.course, startTime: next.startDate)
            } else {
                LADebug.log(String(format: "下节课 %@ 在 %.1f 分钟后（窗口外不启动）", next.course.name, minutesUntil))
            }
        } else {
            LADebug.log("无下节课")
        }

        // 如果当前有课，也启动 Live Activity
        // startTime 传课程真实开始时间（而非当前时刻），灵动岛才能显示正确的已上课时长
        if let current = result.current {
            let calendar = Calendar.current
            let midnight = calendar.startOfDay(for: Date())
            let classStart = midnight.addingTimeInterval(Double(ScheduleHelpers.timeToMinutes(current.startTime) ?? 0) * 60)
            let endTime = midnight.addingTimeInterval(Double(ScheduleHelpers.timeToMinutes(current.endTime) ?? 0) * 60)
            startLiveActivity(for: current, startTime: classStart, endTime: endTime)
        }
    }

    /// 启动 Live Activity
    static func startLiveActivity(for course: Course, startTime: Date, endTime: Date = Date()) {
        // 检查是否已有同课程的 Live Activity
        let existingActivities = Activity<CourseActivityAttributes>.activities
        for activity in existingActivities {
            if activity.attributes.courseId == course.id {
                updateLiveActivity(activity, for: course, startTime: startTime, endTime: endTime)
                return
            }
        }

        let petResult = PetStateManager.decideAction(
            courses: [],
            charging: false,
            lowBattery: ProcessInfo.processInfo.isLowPowerModeEnabled,
            musicPlaying: false
        )

        let attributes = CourseActivityAttributes(
            courseId: course.id,
            startWeek: course.startWeek,
            endWeek: course.endWeek,
            weekParity: course.weekParity.rawValue
        )

        let contentState = CourseActivityAttributes.ContentState(
            courseName: course.name,
            location: course.location,
            countdownText: ScheduleHelpers.countdownText(to: startTime),
            petAction: petResult.action,
            petFrame: 0,
            bubbleText: petResult.bubble,
            courseStartTime: startTime,
            courseEndTime: endTime
        )

        do {
            let activity = try Activity.request(
                attributes: attributes,
                contentState: contentState,
                pushType: nil
            )
            LADebug.log("课程岛启动成功：\(course.name)（id=\(activity.id.prefix(8))）")
            startPeriodicUpdates(for: activity, course: course, startTime: startTime, endTime: endTime)
        } catch {
            LADebug.log("课程岛启动失败：\(error.localizedDescription)")
        }
    }

    /// 更新现有 Live Activity
    static func updateLiveActivity(_ activity: Activity<CourseActivityAttributes>, for course: Course, startTime: Date, endTime: Date) {
        let contentState = CourseActivityAttributes.ContentState(
            courseName: course.name,
            location: course.location,
            countdownText: ScheduleHelpers.countdownText(to: startTime),
            petAction: "idle",
            petFrame: 0,
            bubbleText: "",
            courseStartTime: startTime,
            courseEndTime: endTime
        )
        if #available(iOS 16.2, *) {
            Task { try? await activity.update(ActivityContent(state: contentState, staleDate: nil)) }
        } else {
            Task { try? await activity.update(using: contentState) }
        }
    }

    /// 结束 Live Activity
    static func endLiveActivity(for courseId: String) {
        let activities = Activity<CourseActivityAttributes>.activities
        for activity in activities where activity.attributes.courseId == courseId {
            if #available(iOS 16.2, *) {
                Task { await activity.end(nil, dismissalPolicy: .immediate) }
            } else {
                Task { await activity.end(using: nil, dismissalPolicy: .immediate) }
            }
            print("[LiveActivity] 已结束：\(courseId)")
        }
    }

    // MARK: - 定时更新
    private static var updateTimers: [String: Timer] = [:]

    /// 只负责"课程结束时下岛"；倒计时由视图内 Text(style: .timer) 系统驱动，
    /// 不再每秒 update contentState —— 每秒更新会耗尽系统更新预算，导致时间看起来"不动"。
    private static func startPeriodicUpdates(
        for activity: Activity<CourseActivityAttributes>,
        course: Course,
        startTime: Date,
        endTime: Date
    ) {
        var timer: Timer?
        timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { _ in
            if Date() >= endTime {
                timer?.invalidate()
                endLiveActivity(for: course.id)
            }
        }
        if let t = timer {
            updateTimers[activity.id] = t
        }
    }
}
