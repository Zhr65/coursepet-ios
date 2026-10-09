// MARK: - Live Activity 启动管理器
// 负责在课前 15 分钟自动启动 Live Activity
import ActivityKit
import SwiftUI
import Foundation

enum LiveActivityManager {
    /// 检查是否有课程将在 30 分钟内开始，如有则启动 Live Activity
    /// 专注岛优先级最高：有专注 Activity 时直接 end 课程岛并 return
    static func checkAndStartIfNeeded() {
        // ── 优先级：专注岛 > 课程岛 ──
        // ActivityKit 系统同时只显示一个岛，两个都在时谁先 start 谁占坑，
        // 但冷启动/切前台都可能把课程岛重新拉起来盖住专注岛。
        // 直接扫专注 Activity 列表，有就 end 掉所有课程岛并 return。
        let focusActivities = Activity<FocusActivityAttributes>.activities
        if !focusActivities.isEmpty {
            LADebug.log("专注岛活跃（\(focusActivities.count) 个），课程岛让位")
            endAllCourseActivities()
            return
        }

        let enabled = ActivityAuthorizationInfo().areActivitiesEnabled
        LADebug.log("检查课程岛：系统实时活动授权=\(enabled)")
        guard enabled else {
            LADebug.log("拦截：未授权实时活动（去 系统设置→CoursePet→实时活动 开启）")
            return
        }

        let dataManager = DataManager.shared
        let state = dataManager.loadState()
        let semesterStart = dataManager.semesterStartDate
        guard !semesterStart.isEmpty else {
            LADebug.log("拦截：开学日期未设置 → 去 设置→基础 选择开学日期后即可上岛")
            return
        }

        let weekNum = WeekMath.currentWeekNumber(startDateStr: semesterStart) ?? 1
        let weekCourses = ScheduleHelpers.courses(forWeek: weekNum, courses: state.courses)
        LADebug.log("学期第\(weekNum)周，本周课程 \(weekCourses.count) 门")
        let result = ScheduleHelpers.currentAndNext(courses: weekCourses, at: Date())

        // 正在上着课：所有课程岛立即消失（到点该消失了，别管下课）
        if result.current != nil {
            LADebug.log("上课中：清理所有课程岛")
            endAllCourseActivities()
            return
        }

        // 只显示"距离上课的倒计时"——30 分钟窗口内启动，到上课时刻自动下岛
        if let next = result.next {
            let minutesUntil = next.startDate.timeIntervalSince(Date()) / 60
            if minutesUntil > 0 && minutesUntil <= 30 {
                LADebug.log(String(format: "命中课前窗口：%@ 还有 %.1f 分钟", next.course.name, minutesUntil))
                let calendar = Calendar.current
                let midnight = calendar.startOfDay(for: next.startDate)
                let startMinutes = ScheduleHelpers.timeToMinutes(next.course.startTime) ?? 480
                let endMinutes = ScheduleHelpers.timeToMinutes(next.course.endTime) ?? (startMinutes + 45)
                let classEnd = midnight.addingTimeInterval(Double(endMinutes) * 60)
                startLiveActivity(for: next.course, startTime: next.startDate, endTime: classEnd)
            } else {
                LADebug.log(String(format: "下节课 %@ 在 %.1f 分钟后（窗口外不启动，清残留）", next.course.name, minutesUntil))
                endAllCourseActivities()
            }
        } else {
            LADebug.log("无下节课，清残留")
            endAllCourseActivities()
        }
    }

    /// 本地去重表：Activity.activities 列表更新有延迟（request 后短时间内新活动不在列表里），
    /// request 成功后立即记录到本地，防止高频检查（scenePhase 连续变化）重复启动同一课程
    private static var recentStartDates: [String: Date] = [:]

    /// 统一构造 ContentState（启动与周期更新共用，保证字段一致）
    private static func makeState(course: Course, startTime: Date, endTime: Date) -> CourseActivityAttributes.ContentState {
        let petResult = PetStateManager.decideAction(
            courses: [],
            charging: false,
            lowBattery: ProcessInfo.processInfo.isLowPowerModeEnabled,
            musicPlaying: false
        )
        return CourseActivityAttributes.ContentState(
            courseName: course.name,
            location: course.location,
            countdownText: ScheduleHelpers.countdownText(to: startTime),
            petAction: petResult.action,
            petFrame: 0,
            // Agent 回复走 updateAgentReply 单独写入；日常构造置空，
            // 让锁屏卡片回落到视图内置的确定性语录（petQuote）
            bubbleText: "",
            courseStartTime: startTime,
            courseEndTime: endTime,
            isClassStarted: Date() >= startTime,
            charId: DataManager.shared.charId
        )
    }

    // MARK: Agent 回复上灵动岛（扩展点：宠物在锁屏卡片/展开区开口回话）
    // 仅当有活跃课程 Live Activity 时生效（无载体时不强造活动）。
    // 基于 contentState 原地改写，课程信息/倒计时全部保留，只换气泡与宠物表情。
    static func updateAgentReply(_ text: String) {
        let activities = Activity<CourseActivityAttributes>.activities
        guard !activities.isEmpty else { return }
        let reply = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reply.isEmpty else { return }
        let clipped = String(reply.prefix(40))  // 锁屏卡片一行放得下
        for activity in activities {
            var state = activity.contentState
            state.bubbleText = clipped
            state.petAction = "happy"  // 回话时切开心表情，与"在说话"呼应
            if #available(iOS 16.2, *) {
                // staleDate 保持课程开始时刻（置 nil 会洗掉「到点自动消失」机制）
                Task { try? await activity.update(ActivityContent(state: state, staleDate: state.courseStartTime)) }
            } else {
                Task { try? await activity.update(using: state) }
            }
            LADebug.log("Agent 回复已上岛：\(clipped.prefix(16))…")
        }
    }

    /// 启动 Live Activity
    static func startLiveActivity(for course: Course, startTime: Date, endTime: Date = Date()) {
        // 30 秒内同一课程只允许启动一次（activities 属性更新有延迟，仅靠列表去重不可靠）
        if let last = recentStartDates[course.id], Date().timeIntervalSince(last) < 30 {
            LADebug.log("跳过重复启动：\(course.name)（30 秒内已启动过）")
            return
        }

        // 检查是否已有同课程的 Live Activity
        let existingActivities = Activity<CourseActivityAttributes>.activities
        for activity in existingActivities {
            if activity.attributes.courseId == course.id {
                updateLiveActivity(activity, for: course, startTime: startTime, endTime: endTime)
                return
            }
        }

        let attributes = CourseActivityAttributes(
            courseId: course.id,
            startWeek: course.startWeek,
            endWeek: course.endWeek,
            weekParity: course.weekParity.rawValue
        )

        let contentState = makeState(course: course, startTime: startTime, endTime: endTime)

        do {
            // staleDate = 上课时刻（iOS 16.2+）：App 被杀死后没人调 end 时，
            // 系统到点会把 Activity 标记为 stale 并重渲染视图，视图层看到 isStale
            // 就渲染成空 → 灵动岛/锁屏横幅到点自动「消失」，不再卡 0:00
            let activity: Activity<CourseActivityAttributes>
            if #available(iOS 16.2, *) {
                activity = try Activity.request(
                    attributes: attributes,
                    content: ActivityContent(state: contentState, staleDate: startTime),
                    pushType: nil
                )
            } else {
                activity = try Activity.request(attributes: attributes, contentState: contentState, pushType: nil)
            }
            LADebug.log("课程岛启动成功：\(course.name)（id=\(activity.id.prefix(8))）")
            // 立即记录到本地去重表（activities 列表更新有延迟）
            recentStartDates[course.id] = Date()
            startPeriodicUpdates(for: activity, course: course, startTime: startTime)
        } catch {
            LADebug.log("课程岛启动失败：\(error.localizedDescription)")
        }
    }

    /// 更新现有 Live Activity
    static func updateLiveActivity(_ activity: Activity<CourseActivityAttributes>, for course: Course, startTime: Date, endTime: Date) {
        let contentState = makeState(course: course, startTime: startTime, endTime: endTime)
        if #available(iOS 16.2, *) {
            Task { try? await activity.update(ActivityContent(state: contentState, staleDate: startTime)) }
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

    /// 周期更新：App 活着时盯住上课时刻，到点立即下岛（上课即消失，不等下课）。
    /// App 被杀死的兜底：staleDate（=上课时刻）到点系统重渲染，视图 isStale 渲染空。
    private static func startPeriodicUpdates(
        for activity: Activity<CourseActivityAttributes>,
        course: Course,
        startTime: Date
    ) {
        var timer: Timer?
        timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { _ in
            if Date() >= startTime {
                timer?.invalidate()
                endLiveActivity(for: course.id)
            }
        }
        if let t = timer {
            updateTimers[activity.id] = t
        }
    }

    /// 结束所有课程 Live Activity（无课程命中时清理残留）
    private static func endAllCourseActivities() {
        let activities = Activity<CourseActivityAttributes>.activities
        guard !activities.isEmpty else { return }
        for activity in activities {
            if #available(iOS 16.2, *) {
                Task { await activity.end(nil, dismissalPolicy: .immediate) }
            } else {
                Task { await activity.end(using: nil, dismissalPolicy: .immediate) }
            }
            LADebug.log("清理残留课程岛：\(activity.attributes.courseId.prefix(8))")
        }
    }
}
