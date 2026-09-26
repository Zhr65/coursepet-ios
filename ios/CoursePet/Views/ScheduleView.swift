// MARK: - 周课表视图 v3（真正的整周课表网格 + 液态玻璃）
// 结构：问候条 → 周导航 → 紧凑今日横条 → 整周网格（左侧时间列 + 7 天课程块绝对定位）
import SwiftUI

struct ScheduleMainView: View {
    @EnvironmentObject var dataManager: DataManager
    // 当前查看的周数（打开页面时默认为真实当前周）
    @State private var displayWeek: Int = 1
    // 右上角菜单对应的弹层
    @State private var showImportSheet = false
    @State private var showScanSheet = false
    @State private var showAddCourseSheet = false
    @State private var showClearConfirm = false
    // 点击课程块弹出的编辑弹层
    @State private var editingCourse: Course?
    // 倒计时每秒刷新用的心跳
    @State private var lastTick: Date = Date()
    // 未来 7 天天气（onAppear 异步拉取；定位/网络失败时为空，隐藏天气行）
    @State private var weatherDays: [DayWeather] = []

    private let days = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]
    private let dayShort = ["一", "二", "三", "四", "五", "六", "日"]

    // ── 网格参数 ──
    private let dayStartMinutes = 10 * 60       // 网格起点 10:00（600 分钟）
    private let dayEndMinutes = 20 * 60         // 网格终点 20:00（1200 分钟）
    private let rowHeight: CGFloat = 52         // 每小时行高
    private let timeColumnWidth: CGFloat = 38   // 左侧时间列宽

    /// 课程块深灰文字（浅马卡龙底上保证对比度，深色模式下底色不变仍清晰）
    private static let blockText = Color(red: 0.24, green: 0.26, blue: 0.31)
    /// 马卡龙浅色板（按课程名 hash 取色：浅粉/浅蓝/浅绿/浅黄/浅紫/浅橙）
    private static let macaronColors: [Color] = [
        Color(hex: "#FFD6E0") ?? .pink,    // 浅粉
        Color(hex: "#C9E4FF") ?? .blue,    // 浅蓝
        Color(hex: "#CDF3D8") ?? .green,   // 浅绿
        Color(hex: "#FFF3C4") ?? .yellow,  // 浅黄
        Color(hex: "#E4D9FF") ?? .purple,  // 浅紫
        Color(hex: "#FFE3C2") ?? .orange   // 浅橙
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                // 自定义渐变背景（随设置的主题变化，深色模式自动加深）
                themeBackground.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 12) {
                        headerBar          // 大标题 + 问候
                        weekNavCard        // 周导航（玻璃卡）
                        todayBarCard       // 今日课程横条 + 倒计时（玻璃卡）
                        gridCard           // 整周课表网格（玻璃卡）
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 4)
                    .padding(.bottom, 24)
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // 右上角 + Menu（导入 / 添加 / 清空）
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button {
                            showImportSheet = true
                        } label: {
                            Label("导入课表", systemImage: "doc.badge.plus")
                        }
                        Button {
                            showScanSheet = true
                        } label: {
                            Label("截图识别导入", systemImage: "doc.text.viewfinder")
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
            // ── 课表截图 OCR 导入 ──
            .sheet(isPresented: $showScanSheet) {
                ScheduleScanView()
                    .environmentObject(dataManager)
            }
            // ── 手动添加课程 ──
            .sheet(isPresented: $showAddCourseSheet) {
                AddCourseView()
                    .environmentObject(dataManager)
            }
            // ── 点击课程块编辑 / 删除 ──
            .sheet(item: $editingCourse) { course in
                AddCourseView(course: course)
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
            // 拉取未来 7 天天气（Open-Meteo 免费接口，失败时静默隐藏天气行）
            WeatherManager.fetchDailyWeather { days in
                weatherDays = days
            }
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

    // MARK: - 顶部问候条（大标题 + 副标题 + 今日天气）
    private var headerBar: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("课表")
                .font(.title)
                .fontWeight(.bold)
            Text(greetingText)
                .font(.caption)
                .foregroundColor(.secondary)
            // 今日天气行（拉取失败或无定位时自动隐藏）
            if let today = todayWeather {
                HStack(spacing: 4) {
                    Image(systemName: today.symbol)
                    Text("\(today.description) \(Int(today.tempMin))~\(Int(today.tempMax))°C")
                    if today.rainy {
                        Text("· 记得带伞 ☔")
                    }
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 今天这一天的天气（无数据返回 nil）
    private var todayWeather: DayWeather? {
        weatherDays.first { Calendar.current.isDate($0.date, inSameDayAs: Date()) }
    }

    /// 按当前时段生成问候语
    private var greetingText: String {
        let hour = Calendar.current.component(.hour, from: Date())
        let prefix: String
        switch hour {
        case 5..<11:   prefix = "早上好"
        case 11..<13:  prefix = "中午好"
        case 13..<18:  prefix = "下午好"
        default:       prefix = "晚上好"
        }
        return "\(prefix)，今天也要加油鸭 ✨"
    }

    // MARK: - 周导航（玻璃卡）
    private var weekNavCard: some View {
        GlassCard(padding: 10) {
            HStack(spacing: 8) {
                Button {
                    // 上一周，下限保护：不早于第 1 周
                    guard displayWeek > 1 else { return }
                    withAnimation { displayWeek -= 1 }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.body)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                }

                Spacer()

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

                Spacer()

                Button {
                    // 下一周
                    withAnimation { displayWeek += 1 }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.body)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                }

                Button("今天") {
                    // 回到真实当前周
                    withAnimation { displayWeek = currentWeekNumber }
                }
                .font(.subheadline)
                .foregroundColor(.indigo)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.indigo.opacity(0.12))
                .cornerRadius(8)
            }
        }
    }

    // MARK: - 紧凑今日横条（玻璃卡：今天标题 + 倒计时 chip + 课程 chip 一行）
    private var todayBarCard: some View {
        let result = ScheduleHelpers.currentAndNext(courses: currentWeekCourses, at: lastTick)
        let todayCourses = ScheduleHelpers.courses(forDay: todayDow, courses: currentWeekCourses)

        return GlassCard(padding: 12) {
            VStack(alignment: .leading, spacing: 8) {
                // 第一行：今天 + 倒计时
                HStack {
                    Text("今天 · \(days[todayDow - 1])")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)
                    Spacer()
                    if let current = result.current {
                        // 上课中：距下课倒计时
                        let endSeconds = Double((ScheduleHelpers.timeToMinutes(current.endTime) ?? 0) * 60)
                        let endTime = Calendar.current.startOfDay(for: lastTick).addingTimeInterval(endSeconds)
                        countdownChip(
                            text: "上课中 · \(current.name)",
                            time: ScheduleHelpers.countdownText(to: endTime, from: lastTick),
                            color: .green
                        )
                    } else if let next = result.next {
                        // 下节课：距上课倒计时
                        countdownChip(
                            text: "下节 · \(next.course.name)",
                            time: ScheduleHelpers.countdownText(to: next.startDate, from: lastTick),
                            color: .orange
                        )
                    }
                }
                // 第二行：课程 chip 横排（无课显示一行提示）
                if todayCourses.isEmpty {
                    Text("今天没有课 🎉")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(todayCourses) { course in
                                todayChip(course)
                            }
                        }
                    }
                }
            }
        }
    }

    /// 倒计时小胶囊
    private func countdownChip(text: String, time: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(text)
                .font(.caption2)
                .foregroundColor(.primary)
                .lineLimit(1)
            Text(time)
                .font(.caption2)
                .fontWeight(.bold)
                .foregroundColor(color)
                .monospacedDigit()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.12))
        .clipShape(Capsule())
    }

    /// 今日课程小 chip
    private func todayChip(_ course: Course) -> some View {
        let color = macaronColor(for: course.name)
        return VStack(alignment: .leading, spacing: 1) {
            Text(course.name)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(Self.blockText)
                .lineLimit(1)
            Text("\(course.startTime) \(course.location)")
                .font(.caption2)
                .foregroundColor(Self.blockText.opacity(0.7))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(color)
        .cornerRadius(10)
    }

    // MARK: - 整周课表网格（玻璃卡）
    private var gridCard: some View {
        GlassCard(padding: 10) {
            VStack(spacing: 0) {
                // 表头：时间列占位 + 7 天表头（与网格列宽严格对齐）
                HStack(spacing: 0) {
                    Color.clear
                        .frame(width: timeColumnWidth, height: 26)
                    dayHeaderRow
                }
                // 网格主体：左侧时间列 + 右侧绝对定位课程块
                HStack(alignment: .top, spacing: 0) {
                    timeColumn
                    weekGrid
                }
            }
        }
    }

    /// 7 天表头（今天列高亮胶囊）
    private var dayHeaderRow: some View {
        GeometryReader { geo in
            let colWidth = geo.size.width / 7
            HStack(spacing: 0) {
                ForEach(0..<7, id: \.self) { dayIndex in
                    let isToday = (dayIndex + 1 == todayDow) && isViewingCurrentWeek
                    Text(dayShort[dayIndex])
                        .font(.caption2)
                        .fontWeight(isToday ? .bold : .medium)
                        .foregroundColor(isToday ? .white : .secondary)
                        .frame(width: colWidth, height: 22)
                        .background(
                            Capsule()
                                .fill(isToday ? Color.indigo : Color.clear)
                                .padding(.horizontal, 6)
                        )
                        .frame(width: colWidth, height: 26)
                }
            }
        }
        .frame(height: 26)
    }

    /// 左侧时间列（10:00 ~ 20:00，每小时一个标签，行高与网格一致）
    private var timeColumn: some View {
        VStack(spacing: 0) {
            ForEach(0..<gridHours, id: \.self) { hourIndex in
                Text(String(format: "%02d:00", dayStartMinutes / 60 + hourIndex))
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .frame(width: timeColumnWidth, height: rowHeight, alignment: .topTrailing)
                    .padding(.trailing, 4)
            }
        }
        .frame(width: timeColumnWidth)
    }

    /// 右侧 7 列网格：GeometryReader + ZStack 绝对定位课程块
    private var weekGrid: some View {
        GeometryReader { geo in
            let colWidth = geo.size.width / 7
            ZStack(alignment: .topLeading) {
                // 今天列高亮底色
                ForEach(0..<7, id: \.self) { dayIndex in
                    let isToday = (dayIndex + 1 == todayDow) && isViewingCurrentWeek
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isToday ? Color.indigo.opacity(0.08) : Color.clear)
                        .frame(width: colWidth - 2, height: CGFloat(gridHours) * rowHeight)
                        .offset(x: CGFloat(dayIndex) * colWidth + 1)
                }
                // 每小时横线
                ForEach(1..<gridHours, id: \.self) { hourIndex in
                    Rectangle()
                        .fill(Color.secondary.opacity(0.15))
                        .frame(width: geo.size.width, height: 0.5)
                        .offset(y: CGFloat(hourIndex) * rowHeight)
                }
                // 课程块（ForEach id 用课程唯一 id）
                ForEach(visibleCourses) { course in
                    courseBlock(course, colWidth: colWidth)
                }
            }
        }
        .frame(height: CGFloat(gridHours) * rowHeight)
    }

    /// 单个课程块：按课程名取马卡龙浅色 + 深灰文字，上课中加紫色描边
    private func courseBlock(_ course: Course, colWidth: CGFloat) -> some View {
        // 时间换算成网格坐标（越界部分钳制在网格范围内）
        let rawStart = ScheduleHelpers.timeToMinutes(course.startTime) ?? dayStartMinutes
        let rawEnd = ScheduleHelpers.timeToMinutes(course.endTime) ?? (rawStart + 60)
        let startMin = max(dayStartMinutes, rawStart)
        let endMin = max(min(dayEndMinutes, rawEnd), startMin + 20)   // 至少显示 20 分钟高度
        let offsetY = CGFloat(startMin - dayStartMinutes) / 60 * rowHeight
        let blockHeight = CGFloat(endMin - startMin) / 60 * rowHeight - 3
        let color = macaronColor(for: course.name)
        let isCurrent = isViewingCurrentWeek && currentCourseId == course.id

        return VStack(alignment: .leading, spacing: 2) {
            Text(course.name)
                .font(.caption2)
                .fontWeight(.semibold)
                .foregroundColor(Self.blockText)
                .lineLimit(3)
            Text(course.location)
                .font(.caption2)
                .foregroundColor(Self.blockText.opacity(0.75))
                .lineLimit(2)
            Spacer(minLength: 0)
            Text("\(course.startTime)-\(course.endTime)")
                .font(.system(size: 8))
                .foregroundColor(Self.blockText.opacity(0.6))
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 4)
        .frame(width: colWidth - 6, height: max(20, blockHeight), alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(color)
        )
        // 当前正在进行的课程：紫色描边高亮
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isCurrent ? Color.purple : Color.clear, lineWidth: 2)
        )
        // 绝对定位：x = 星期列偏移，y = 开始时间偏移
        .offset(x: CGFloat(course.dayOfWeek - 1) * colWidth + 3, y: offsetY)
        // 点击课程块 → 编辑 / 删除
        .onTapGesture { editingCourse = course }
    }

    /// 按课程名 hash 稳定取马卡龙浅色（同名课程同色，跨启动一致）
    private func macaronColor(for name: String) -> Color {
        var hash = 0
        for scalar in name.unicodeScalars {
            hash = (hash &* 31 &+ Int(scalar.value)) & 0x7FFFFFFF
        }
        return Self.macaronColors[hash % Self.macaronColors.count]
    }

    // MARK: - 计算属性
    /// 网格覆盖的小时数（10:00 ~ 20:00 共 10 格）
    private var gridHours: Int {
        (dayEndMinutes - dayStartMinutes) / 60
    }

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

    /// 当前周的课程（用于今日横条与上课中高亮，始终以真实周为准）
    private var currentWeekCourses: [Course] {
        return ScheduleHelpers.courses(forWeek: currentWeekNumber, courses: dataManager.courses)
    }

    /// 查看周的课程（用于周表格子，按星期几与开始时间排序；
    /// 与 10:00-20:00 网格无时间交集的课程不显示，避免钳制错乱）
    private var visibleCourses: [Course] {
        let weekCourses = ScheduleHelpers.courses(forWeek: displayWeek, courses: dataManager.courses)
        return weekCourses
            .filter { course in
                let start = ScheduleHelpers.timeToMinutes(course.startTime) ?? 0
                let end = ScheduleHelpers.timeToMinutes(course.endTime) ?? start
                return end > dayStartMinutes && start < dayEndMinutes
            }
            .sorted {
                ($0.dayOfWeek, ScheduleHelpers.timeToMinutes($0.startTime) ?? 0) <
                ($1.dayOfWeek, ScheduleHelpers.timeToMinutes($1.startTime) ?? 0)
            }
    }

    /// 当前正在上的课（紫色描边高亮用）
    private var currentCourseId: String? {
        ScheduleHelpers.currentAndNext(courses: currentWeekCourses, at: Date()).current?.id
    }
}
