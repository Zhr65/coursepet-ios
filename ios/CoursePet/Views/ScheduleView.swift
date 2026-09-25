// MARK: - 周课表视图 v2（完整实现，含 NavigationStack）
import SwiftUI

struct ScheduleMainView: View {
    @EnvironmentObject var dataManager: DataManager
    // 当前查看的周数（打开页面时默认为真实当前周）
    @State private var displayWeek: Int = 1
    // 右上角菜单对应的弹层
    @State private var showImportSheet = false
    @State private var showAddCourseSheet = false
    @State private var showClearConfirm = false
    // 倒计时每秒刷新用的心跳
    @State private var lastTick: Date = Date()

    private let days = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]

    var body: some View {
        NavigationStack {
            ZStack {
                // 自定义渐变背景（随设置的主题变化，深色模式自动加深）
                themeBackground.ignoresSafeArea()

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
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button {
                            showImportSheet = true
                        } label: {
                            Label("导入课表", systemImage: "doc.badge.plus")
                        }
                        Button {
                            showAddCourseSheet = true
                        } label: {
                            Label("添加课程", systemImage: "plus.circle")
                        }
                        Button(role: .destructive) {
                            showClearConfirm = true
                        } label: {
                            Label("清空全部", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            // ── 导入课表 ──
            .sheet(isPresented: $showImportSheet) {
                ExcelImportView()
                    .environmentObject(dataManager)
            }
            // ── 手动添加课程 ──
            .sheet(isPresented: $showAddCourseSheet) {
                AddCourseView()
                    .environmentObject(dataManager)
            }
            // ── 清空全部二次确认 ──
            .confirmationDialog("清空全部课程", isPresented: $showClearConfirm, titleVisibility: .visible) {
                Button("清空全部课程", role: .destructive) {
                    dataManager.clearCourses()
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("将删除所有课程数据，此操作不可撤销。")
            }
        }
        .onAppear {
            // 打开页面时回到真实当前周
            displayWeek = currentWeekNumber
        }
        .task(id: currentWeekNumber) {
            // 每秒刷新倒计时（lastTick 变化触发 body 重算）
            while true {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                withAnimation { lastTick = Date() }
            }
        }
    }

    // MARK: - 背景主题
    private var themeBackground: some View {
        ZStack {
            LinearGradient(
                colors: BackgroundTheme.named(dataManager.backgroundColorName).colors,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            // 深色模式下叠一层黑色自动加深
            Color.black.opacity(dataManager.darkMode ? 0.45 : 0)
        }
    }

    // MARK: - 倒计时 Banner
    private var countdownBanner: some View {
        let now = Date()
        let result = ScheduleHelpers.currentAndNext(
            courses: currentWeekCourses,
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
                .background(Color(.systemBackground).opacity(0.8))
                .cornerRadius(12)
                .padding(.horizontal, 12)
                .padding(.top, 8)
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
                .background(Color(.systemBackground).opacity(0.8))
                .cornerRadius(12)
                .padding(.horizontal, 12)
                .padding(.top, 8)
            }
        }
    }

    // MARK: - 周导航
    private var weekHeader: some View {
        HStack {
            Button {
                // 上一周，下限保护：不早于第 1 周
                guard displayWeek > 1 else { return }
                withAnimation { displayWeek -= 1 }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.title3)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }

            HStack(spacing: 6) {
                Text(weekTitle)
                    .font(.headline)
                    .fontWeight(.semibold)
                if !isViewingCurrentWeek {
                    // 手动查看非当前周时的标记
                    Text("查看中")
                        .font(.caption2)
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange)
                        .clipShape(Capsule())
                }
            }

            Button {
                // 下一周
                withAnimation { displayWeek += 1 }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.title3)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }

            Spacer()

            Button("今天") {
                // 回到真实当前周
                withAnimation { displayWeek = currentWeekNumber }
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
        .background(Color(.systemBackground).opacity(0.55))
    }

    // MARK: - 周表格子
    private var weekGrid: some View {
        let courses = visibleCourses
        // 7 等分列定义，直接铺满屏幕宽度（不套横向 ScrollView，避免内容塌缩）
        let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)
        return LazyVGrid(columns: columns, spacing: 8) {
            ForEach(days.indices, id: \.self) { dayIndex in
                VStack(spacing: 4) {
                    Text(days[dayIndex])
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(dayIndex + 1 == todayDow ? .indigo : .secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                        .background(Color(.systemGray5).opacity(0.7))
                        .cornerRadius(4)

                    let dayCourses = courses.filter { $0.dayOfWeek == dayIndex + 1 }
                    ForEach(dayCourses) { course in
                        courseChip(course)
                    }
                    // 无课时保持占位高度，避免格子塌缩
                    if dayCourses.isEmpty {
                        Rectangle()
                            .fill(Color(.systemGray5).opacity(0.25))
                            .frame(height: 32)
                            .cornerRadius(4)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
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
        let todayCourses = ScheduleHelpers.courses(forDay: todayDow, courses: currentWeekCourses)

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
                        .padding(.horizontal, 12)
                }
            }
        }
        .padding(.bottom, 20)
    }

    private func todayCourseRow(_ course: Course) -> some View {
        let color = Color(hex: course.color) ?? Color.orange
        let result = ScheduleHelpers.currentAndNext(courses: currentWeekCourses, at: Date())
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
        .background(isCurrent ? color.opacity(0.12) : Color(.systemBackground).opacity(0.8))
        .cornerRadius(12)
        .shadow(color: isCurrent ? color.opacity(0.2) : .clear, radius: 2, y: 1)
        .onTapGesture { /* 编辑课程 */ }
    }

    // MARK: - 计算属性
    /// 今天是星期几（1=周一 … 7=周日）
    private var todayDow: Int {
        let g = Calendar.current.component(.weekday, from: Date())
        return g == 1 ? 7 : g - 1
    }

    /// 真实当前周（学期开始日期来自 DataManager 设置；未设置时兜底第 1 周）
    private var currentWeekNumber: Int {
        return WeekMath.currentWeekNumber(
            startDateStr: dataManager.semesterStartDate,
            now: Date()
        ) ?? 1
    }

    /// 是否正在查看真实当前周
    private var isViewingCurrentWeek: Bool {
        return displayWeek == currentWeekNumber
    }

    private var weekTitle: String {
        let parity = WeekMath.weekParity(of: displayWeek)
        let parityText = parity == .single ? "单周" : "双周"
        return "第 \(displayWeek) 周 · \(parityText)"
    }

    /// 当前周的课程（用于倒计时条与今日列表，始终以真实周为准）
    private var currentWeekCourses: [Course] {
        return ScheduleHelpers.courses(forWeek: currentWeekNumber, courses: dataManager.courses)
    }

    /// 查看周的课程（用于周表格子）
    private var visibleCourses: [Course] {
        let weekCourses = ScheduleHelpers.courses(forWeek: displayWeek, courses: dataManager.courses)
        return weekCourses.sorted {
            ($0.dayOfWeek, ScheduleHelpers.timeToMinutes($0.startTime) ?? 0) <
            ($1.dayOfWeek, ScheduleHelpers.timeToMinutes($1.startTime) ?? 0)
        }
    }

    private var calendarStartOfDay: (Date) -> Date { { Calendar.current.startOfDay(for: $0) } }
}
