// MARK: - Live Activity 启动管理器
// 负责在课前 15 分钟自动启动 Live Activity
import ActivityKit
import SwiftUI
import Foundation

enum LiveActivityManager {
    /// 检查是否有课程将在 15 分钟内开始，如有则启动 Live Activity
    static func checkAndStartIfNeeded() {
        guard !ActivityAuthorizationInfo().areActivitiesEnabled else {
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
        if let current = result.current {
            let calendar = Calendar.current
            let midnight = calendar.startOfDay(for: Date())
            let endTime = midnight.addingTimeInterval(Double(ScheduleHelpers.timeToMinutes(current.endTime) ?? 0) * 60)
            startLiveActivity(for: current, startTime: Date(), endTime: endTime)
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

    private static func startPeriodicUpdates(
        for activity: Activity<CourseActivityAttributes>,
        course: Course,
        startTime: Date,
        endTime: Date
    ) {
        var timer: Timer?
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            let now = Date()
            let remaining = max(0, Int(startTime.timeIntervalSince(now)))
            let countdownText = String(format: "%02d:%02d:%02d", remaining / 3600, (remaining % 3600) / 60, remaining % 60)

            let newState = CourseActivityAttributes.ContentState(
                courseName: course.name,
                location: course.location,
                countdownText: countdownText,
                petAction: "idle",
                petFrame: 0,
                bubbleText: "",
                courseStartTime: startTime,
                courseEndTime: endTime
            )

            if #available(iOS 16.2, *) {
                Task { try? await activity.update(ActivityContent(state: newState, staleDate: nil)) }
            } else {
                Task { try? await activity.update(using: newState) }
            }

            // 课程结束
            if now >= endTime {
                timer?.invalidate()
                endLiveActivity(for: course.id)
            }
        }
        if let t = timer {
            updateTimers[activity.id] = t
        }
    }
}
