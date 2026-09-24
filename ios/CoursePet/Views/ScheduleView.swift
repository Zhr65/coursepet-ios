// MARK: - 周课表视图 v2（完整实现，含 NavigationStack）
import SwiftUI
import Shared

struct ScheduleMainView: View {
    @EnvironmentObject var dataManager: DataManager
    @State private var viewingWeekOffset: Int = 0

    private let days = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    // ── 倒计时条 ──
                    countdownBanner

                    // ── 周导航栏 ──
                    weekHeader

                    // ── 本周格子 ──
                    weekGrid

                    // ── 今日课程列表 ──
                    todayList
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        // 打开导入/管理课表
                    } label: {
                        Image(systemName: "plus")
                    }
                    .menu {
                        Menu("课表管理", systemImage: "calendar.badge.plus") {
                            Button {
                                // 导入 Excel
                            } label: {
                                Label("导入课表", systemImage: "doc.badge.plus")
                            }
                            Button {
                                // 手动添加
                            } label: {
                                Label("添加课程", systemImage: "plus.circle")
                            }
                            Button {
                                // 清空数据
                            } label: {
                                Label("清空全部", systemImage: "trash")
                                    .foregroundColor(.red)
                            }
                        }
                    }
                }
            }
        }
        .onAppear { refreshCurrentWeek() }
        .onChange(of: Date()) { _ in refreshCurrentWeek() }
        .task(id: currentWeekNumber) {
            // 每秒刷新倒计时
            while true {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                withAnimation { lastTick = Date() }
            }
        }
    }

    // MARK: - 倒计时 Banner
    private var countdownBanner: some View {
        let now = Date()
        let result = ScheduleHelpers.currentAndNext(
            courses: activeCourses,
            at: now
        )

        return Group {
            if let current = result.current {
                // 上课中
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("正在上课")
                            .font(.caption2)
                            .foregroundColor(.white.opacity(0.8))
                        Text(current.name)
                            .font(.body)
                            .fontWeight(.semibold)
                            .foregroundColor(.white)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("剩余")
                            .font(.caption2)
                            .foregroundColor(.white.opacity(0.8))
                        let endTime = calendarStartOfDay(now).addingTimeInterval(
                            Double(ScheduleHelpers.timeToMinutes(current.endTime) ?? 0) * 60
                        )
                        Text(ScheduleHelpers.countdownText(to: endTime, from: now))
                            .font(.title3)
                            .fontWeight(.heavy)
                            .foregroundColor(.white)
                            .monospacedDigit()
                    }
                }
                .padding()
                .background(
                    LinearGradient(
                        colors: [Color(hex: current.color) ?? Color.orange,
                                 (Color(hex: current.color) ?? Color.orange).opacity(0.6)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
            } else if let next = result.next {
                // 下一节
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("下节课")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text("\(next.course.name) · \(next.course.location)")
                            .font(.body)
                            .fontWeight(.medium)
                            .foregroundColor(.primary)
                    }
                    Spacer()
                    Text(ScheduleHelpers.countdownText(to: next.startDate, from: now))
                        .font(.title3)
                        .fontWeight(.heavy)
                        .foregroundColor(.orange)
                        .monospacedDigit()
                }
                .padding()
                .background(Color(.systemBackground))
            } else {
                // 无课
                HStack {
                    Image(systemName: "sun.max.fill")
                        .foregroundColor(.orange)
                    Text("今天没有课，休息一下 🎉")
                        .font(.body)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding()
                .background(Color(.systemBackground))
            }
        }
    }

    // MARK: - 周导航
    private var weekHeader: some View {
        HStack {
            Button {
                withAnimation { viewingWeekOffset = max(-10, viewingWeekOffset - 1) }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.title3)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }

            Text(weekTitle)
                .font(.headline)
                .fontWeight(.semibold)

            Button {
                withAnimation { viewingWeekOffset = viewingWeekOffset + 1 }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.title3)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }

            Spacer()

            Button("今天") {
                withAnimation { viewingWeekOffset = 0 }
            }
            .font(.subheadline)
            .foregroundColor(.indigo)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.indigo.opacity(0.1))
            .cornerRadius(8)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(.systemGroupedBackground))
    }

    // MARK: - 周表格子
    private var weekGrid: some View {
        let courses = visibleCourses
        return ScrollView(.horizontal, showsIndicators: false) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 8) {
                ForEach(days.indices, id: \.self) { dayIndex in
                    VStack(spacing: 4) {
                        Text(days[dayIndex])
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(dayIndex == 4 ? .indigo : .secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                            .background(Color(.systemGray5))
                            .cornerRadius(4)

                        let dayCourses = courses.filter { $0.dayOfWeek == dayIndex + 1 }
                        ForEach(dayCourses) { course in
                            courseChip(course)
                        }
                        if dayCourses.isEmpty {
                            Rectangle()
                                .fill(Color(.systemGray5).opacity(0.3))
                                .frame(height: 32)
                                .cornerRadius(4)
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        }
        .background(Color(.systemGroupedBackground))
    }

    private func courseChip(_ course: Course) -> some View {
        let color = Color(hex: course.color) ?? Color.orange
        return VStack(alignment: .leading, spacing: 1) {
            Text(course.name)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(color)
                .lineLimit(1)
            Text(course.location)
                .font(.system(size: 9))
                .foregroundColor(color.opacity(0.7))
                .lineLimit(1)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.3))
        .cornerRadius(4)
        .onTapGesture { /* 打开编辑 */ }
    }

    // MARK: - 今日课程列表
    private var todayList: some View {
        let todayDow = Calendar.current.component(.weekday, from: Date()) == 1 ? 7 : Calendar.current.component(.weekday, from: Date()) - 1
        let todayCourses = ScheduleHelpers.courses(forDay: todayDow, courses: activeCourses)

        return VStack(alignment: .leading, spacing: 10) {
            Text("今日 · \(days[todayDow - 1])")
                .font(.title3)
                .fontWeight(.semibold)
                .padding(.horizontal, 16)

            if todayCourses.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "calendar.badge.checkmark")
                        .font(.system(size: 48))
                        .foregroundColor(.indigo)
                    Text("今天没有课")
                        .font(.body)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
                .padding(.bottom, 20)
            } else {
                ForEach(todayCourses) { course in
                    todayCourseRow(course)
                }
            }
        }
        .padding(.bottom, 20)
        .background(Color(.systemGroupedBackground))
    }

    private func todayCourseRow(_ course: Course) -> some View {
        let color = Color(hex: course.color) ?? Color.orange
        let result = ScheduleHelpers.currentAndNext(courses: activeCourses, at: Date())
        let isCurrent = result.current?.id == course.id
        let isNext = result.next?.course.id == course.id

        return HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 4)
                .overlay(
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color.opacity(0.3))
                )

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(course.name)
                        .font(.body)
                        .fontWeight(.semibold)
                    if isCurrent {
                        Label("上课中", systemImage: "circle.fill")
                            .font(.caption2)
                            .foregroundColor(.green)
                    }
                    if isNext {
                        Label("下一节", systemImage: "clock")
                            .font(.caption2)
                            .foregroundColor(.orange)
                    }
                    Spacer()
                }
                HStack(spacing: 12) {
                    Label(course.startTime + " – " + course.endTime, systemImage: "clock")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Label(course.location, systemImage: "location.fill")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    if !course.teacher.isEmpty {
                        Label(course.teacher, systemImage: "person.fill")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .padding()
        .background(isCurrent ? color.opacity(0.12) : Color(.systemBackground))
        .cornerRadius(12)
        .shadow(color: isCurrent ? color.opacity(0.2) : .clear, radius: 2, y: 1)
        .onTapGesture { /* 编辑课程 */ }
    }

    // MARK: - 计算属性
    private var baseWeekNumber: Int {
        return WeekMath.currentWeekNumber(startDateStr: dataManager.getSemesterStartDate() ?? "", now: Date()) ?? 1
    }

    private var viewingWeekNumber: Int {
        return max(1, baseWeekNumber + viewingWeekOffset)
    }

    private var weekTitle: String {
        let parity = WeekMath.weekParity(of: viewingWeekNumber)
        let parityText = parity == .single ? "单周" : "双周"
        let suffix = viewingWeekOffset != 0 ? "（查看中）" : ""
        return "第 \(viewingWeekNumber) 周 · \(parityText)\(suffix)"
    }

    private var activeCourses: [Course] {
        return ScheduleHelpers.courses(forWeek: viewingWeekNumber, courses: dataManager.loadState().courses)
    }

    private var visibleCourses: [Course] {
        return activeCourses.sorted {
            ($0.dayOfWeek, ScheduleHelpers.timeToMinutes($0.startTime) ?? 0) <
            ($1.dayOfWeek, ScheduleHelpers.timeToMinutes($1.startTime) ?? 0)
        }
    }

    private var currentWeekNumber: Int { viewingWeekNumber }
    @State private var lastTick: Date = Date()
    private var calendarStartOfDay: (Date) -> Date { { Calendar.current.startOfDay(for: $0) } }

    private func refreshCurrentWeek() {
        let base = baseWeekNumber
        if viewingWeekOffset == 0 {
            // 已在本周，无需操作
        } else {
            viewingWeekOffset = 0
        }
    }
}


