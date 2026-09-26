// MARK: - Live Activity 启动管理器
// 负责在课前 15 分钟自动启动 Live Activity
import ActivityKit
import SwiftUI
import Foundation

enum LiveActivityManager {
    /// 检查是否有课程将在 15 分钟内开始，如有则启动 Live Activity
    static func checkAndStartIfNeeded() {
        // 注意：授权开启（true）才继续；此前写成 !areActivitiesEnabled 导致已授权反而被拦截，永远不上岛
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            print("[LiveActivity] 用户未授权 Live Activity")
            return
        }

        let dataManager = DataManager.shared
        let state = dataManager.loadState()
        let semesterStart = dataManager.getSemesterStartDate() ?? ""
        guard !semesterStart.isEmpty else { return }

        let weekNum = WeekMath.currentWeekNumber(startDateStr: semesterStart) ?? 1
        let weekCourses = ScheduleHelpers.courses(forWeek: weekNum, courses: state.courses)
        let result = ScheduleHelpers.currentAndNext(courses: weekCourses, at: Date())

        // 如果有下节课且在 15 分钟内，启动 Live Activity
        if let next = result.next {
            let minutesUntil = next.startDate.timeIntervalSince(Date()) / 60
            if minutesUntil <= 15 && minutesUntil > 0 {
                startLiveActivity(for: next.course, startTime: next.startDate)
            }
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
            print("[LiveActivity] 已启动：\(course.name)")
            startPeriodicUpdates(for: activity, course: course, startTime: startTime, endTime: endTime)
        } catch {
            print("[LiveActivity] 启动失败：\(error)")
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
