// MARK: - 小组件共享类型（Entry + TimelineProvider）
import WidgetKit
import SwiftUI
import Foundation

// MARK: - 小组件数据入口
struct CoursePetEntry: TimelineEntry {
    let date: Date
    let nextCourse: Course?
    let currentCourse: Course?
    let todayCourses: [Course]
    let weekCourses: [[Course]]   // 7 天的课程
    let petAction: String
    let bubbleText: String
    let charId: String
    let animSpeed: AppSettings.AnimSpeed
    let countdownText: String     // 距下一节课/剩余时间

    init(
        date: Date = Date(),
        nextCourse: Course? = nil,
        currentCourse: Course? = nil,
        todayCourses: [Course] = [],
        weekCourses: [[Course]] = [],
        petAction: String = "idle",
        bubbleText: String = "",
        charId: String = "char1",
        animSpeed: AppSettings.AnimSpeed = .mid,
        countdownText: String = ""
    ) {
        self.date = date
        self.nextCourse = nextCourse
        self.currentCourse = currentCourse
        self.todayCourses = todayCourses
        self.weekCourses = weekCourses
        self.petAction = petAction
        self.bubbleText = bubbleText
        self.charId = charId
        self.animSpeed = animSpeed
        self.countdownText = countdownText
    }
}

// MARK: - TimelineProvider
struct CoursePetTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> CoursePetEntry {
        CoursePetEntry(
            nextCourse: nil,
            currentCourse: nil,
            petAction: "idle",
            countdownText: "--:--:--"
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (CoursePetEntry) -> Void) {
        let entry = loadData(for: context.isPreview)
        completion(entry)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CoursePetEntry>) -> Void) {
        let entry = loadData(for: context.isPreview)
        let now = Date()
        // 确定下次刷新时间：下一节课开始/结束，或 15 分钟后
        let nextRefresh = schedule.nextRefreshDate(from: now)
        let timeline = Timeline(entries: [entry], policy: .after(nextRefresh))
        completion(timeline)
    }

    // MARK: - 数据加载
    private func loadData(isPreview: Bool) -> CoursePetEntry {
        let dataManager = DataManager.shared
        let state = dataManager.loadState()
        let semesterStart = dataManager.getSemesterStartDate() ?? ""

        if isPreview {
            return CoursePetEntry(
                nextCourse: Course(name: "数据结构", teacher: "张教授", location: "3教-201", dayOfWeek: 2, startTime: "10:00", endTime: "11:40"),
                currentCourse: Course(name: "高等数学", teacher: "李教授", location: "1教-101", dayOfWeek: 1, startTime: "08:00", endTime: "09:40"),
                petAction: "idle",
                countdownText: "00:45:00"
            )
        }

        guard !semesterStart.isEmpty else {
            return CoursePetEntry(petAction: "idle", countdownText: "未设置学期")
        }

        let weekNum = WeekMath.currentWeekNumber(startDateStr: semesterStart) ?? 1
        let courses = ScheduleHelpers.courses(forWeek: weekNum, courses: state.courses)
        let result = ScheduleHelpers.currentAndNext(courses: courses, at: Date())

        // 今日课程
        let todayDow: Int = {
            let g = Calendar.current.component(.weekday, from: Date())
            return g == 1 ? 7 : g - 1
        }()
        let todayCourses = ScheduleHelpers.courses(forDay: todayDow, courses: courses)

        // 本周表格（7 天）
        var weekCourses: [[Course]] = []
        for day in 1...7 {
            weekCourses.append(ScheduleHelpers.courses(forDay: day, courses: courses))
        }

        // 宠物状态
        let petResult = PetStateManager.decideAction(
            courses: courses,
            charging: dataManager.loadState().settings.simCharging,
            lowBattery: dataManager.loadState().settings.simLowBattery,
            musicPlaying: dataManager.loadState().settings.simMusic
        )

        // 倒计时文本
        let countdownText: String
        if let current = result.current {
            countdownText = "剩余 \(ScheduleHelpers.countdownText(to: Date().addingTimeInterval(60*40)))" // 简化
        } else if let next = result.next {
            countdownText = ScheduleHelpers.countdownText(to: next.startDate)
        } else {
            countdownText = "暂无课程"
        }

        return CoursePetEntry(
            nextCourse: result.next?.course,
            currentCourse: result.current,
            todayCourses: todayCourses,
            weekCourses: weekCourses,
            petAction: petResult.action,
            bubbleText: petResult.bubble,
            charId: dataManager.getCharId(),
            animSpeed: dataManager.getAnimSpeed(),
            countdownText: countdownText
        )
    }
}

// MARK: - 下次刷新时间计算
extension CoursePetEntry {
    static func scheduleRefreshDate(from now: Date) -> Date {
        let dataManager = DataManager.shared
        let state = dataManager.loadState()
        let semesterStart = dataManager.getSemesterStartDate() ?? ""
        guard !semesterStart.isEmpty else { return now.addingTimeInterval(900) }

        let weekNum = WeekMath.currentWeekNumber(startDateStr: semesterStart) ?? 1
        let courses = ScheduleHelpers.courses(forWeek: weekNum, courses: state.courses)
        let result = ScheduleHelpers.currentAndNext(courses: courses, at: now)

        // 优先在下一节课开始时刷新
        if let next = result.next {
            return next.startDate
        }
        // 如果没有下节课，30 分钟后刷新
        return now.addingTimeInterval(1800)
    }
}

// MARK: - TimelineProvider 扩展
extension CoursePetTimelineProvider {
    func scheduleRefreshDate() -> Date {
        return CoursePetEntry.scheduleRefreshDate(from: Date())
    }
}
