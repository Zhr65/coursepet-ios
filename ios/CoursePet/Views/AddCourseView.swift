// MARK: - 添加 / 编辑课程表单
// 编辑模式：传入已有课程时预填全部字段，保存为原位更新；并支持直接删除课程
import SwiftUI

struct AddCourseView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var dataManager: DataManager

    // 编辑的课程（nil = 添加模式）
    private let editingCourse: Course?
    // 删除二次确认
    @State private var showDeleteConfirm = false

    // MARK: - 表单状态（编辑模式用已有课程预填）
    @State private var courseName: String
    @State private var teacher: String
    @State private var location: String
    @State private var dayOfWeek: Int
    @State private var startTime: Date
    @State private var endTime: Date
    @State private var startWeek: Int
    @State private var endWeek: Int
    @State private var weekParity: WeekParity
    // 校验错误提示
    @State private var errorMessage: String?

    private let dayOptions = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]

    // MARK: - 初始化（course 传 nil = 添加模式）
    init(course: Course? = nil) {
        self.editingCourse = course
        let calendar = Calendar.current
        let now = Date()
        // 网格时间范围 10:00-20:00，默认时间随之调整
        let defaultStart = calendar.date(bySettingHour: 10, minute: 0, second: 0, of: now) ?? now
        let defaultEnd = calendar.date(bySettingHour: 11, minute: 40, second: 0, of: now) ?? now

        if let c = course {
            _courseName = State(initialValue: c.name)
            _teacher = State(initialValue: c.teacher)
            _location = State(initialValue: c.location)
            _dayOfWeek = State(initialValue: c.dayOfWeek)
            _startTime = State(initialValue: Self.parseTime(c.startTime) ?? defaultStart)
            _endTime = State(initialValue: Self.parseTime(c.endTime) ?? defaultEnd)
            _startWeek = State(initialValue: c.startWeek)
            _endWeek = State(initialValue: c.endWeek)
            _weekParity = State(initialValue: c.weekParity)
        } else {
            _courseName = State(initialValue: "")
            _teacher = State(initialValue: "")
            _location = State(initialValue: "")
            _dayOfWeek = State(initialValue: 1)
            _startTime = State(initialValue: defaultStart)
            _endTime = State(initialValue: defaultEnd)
            _startWeek = State(initialValue: 1)
            _endWeek = State(initialValue: 20)
            _weekParity = State(initialValue: .both)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                // ── 课程信息 ──
                Section("📚 课程信息") {
                    TextField("课程名（必填）", text: $courseName)
                    TextField("教师（选填）", text: $teacher)
                    TextField("地点（选填）", text: $location)
                }

                // ── 上课时间 ──
                Section("⏰ 上课时间") {
                    Picker("星期", selection: $dayOfWeek) {
                        ForEach(1...7, id: \.self) { day in
                            Text(dayOptions[day - 1]).tag(day)
                        }
                    }
                    DatePicker("开始时间", selection: $startTime, displayedComponents: .hourAndMinute)
                    DatePicker("结束时间", selection: $endTime, displayedComponents: .hourAndMinute)
                }

                // ── 周次范围 ──
                Section("📆 周次范围") {
                    Stepper("起始周：第 \(startWeek) 周", value: $startWeek, in: 1...25)
                        .onChange(of: startWeek) { newValue in
                            // 结束周不能早于起始周
                            if endWeek < newValue { endWeek = newValue }
                        }
                    Stepper("结束周：第 \(endWeek) 周", value: $endWeek, in: 1...25)
                    Picker("单双周", selection: $weekParity) {
                        Text("每周上课").tag(WeekParity.both)
                        Text("仅单周").tag(WeekParity.single)
                        Text("仅双周").tag(WeekParity.double)
                    }
                }

                // ── 错误提示 ──
                if let message = errorMessage {
                    Section {
                        Text(message)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }

                // ── 去上课：一键导航到教室（仅编辑模式且已填地点时显示）──
                if editingCourse != nil, !location.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Section {
                        Button {
                            openInMaps()
                        } label: {
                            Label("去上课 · 导航到 \(location)", systemImage: "map.fill")
                                .font(.headline)
                                .fontWeight(.semibold)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity)
                                .foregroundColor(.green)
                        }
                    }
                }

                // ── 保存 ──
                Section {
                    Button {
                        saveCourse()
                    } label: {
                        Text(editingCourse == nil ? "保存课程" : "保存修改")
                            .font(.headline)
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                            .foregroundColor(.indigo)
                    }
                }

                // ── 删除（仅编辑模式）──
                if editingCourse != nil {
                    Section {
                        Button(role: .destructive) {
                            showDeleteConfirm = true
                        } label: {
                            Text("删除课程")
                                .fontWeight(.semibold)
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
            .navigationTitle(editingCourse == nil ? "添加课程" : "编辑课程")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { dismiss() }
                }
            }
            .confirmationDialog("删除这门课？", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                Button("删除课程", role: .destructive) {
                    if let editing = editingCourse {
                        dataManager.removeCourse(withId: editing.id)
                    }
                    dismiss()
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("将删除「\(courseName)」的全部周次记录，此操作不可撤销。")
            }
        }
    }

    // MARK: - 保存
    private func saveCourse() {
        let trimmedName = courseName.trimmingCharacters(in: .whitespacesAndNewlines)
        // 校验：课程名必填
        guard !trimmedName.isEmpty else {
            errorMessage = "请填写课程名称"
            return
        }
        // 校验：结束时间需晚于开始时间
        guard endTime > startTime else {
            errorMessage = "结束时间必须晚于开始时间"
            return
        }
        errorMessage = nil

        // 构造课程（color 传 nil，按星期几自动配色）
        var course = Course(
            name: trimmedName,
            teacher: teacher.trimmingCharacters(in: .whitespacesAndNewlines),
            location: location.trimmingCharacters(in: .whitespacesAndNewlines),
            dayOfWeek: dayOfWeek,
            startTime: formatTime(startTime),
            endTime: formatTime(endTime),
            startWeek: startWeek,
            endWeek: endWeek,
            weekParity: weekParity
        )

        if let editing = editingCourse {
            // 编辑模式：保留原 id，原位更新
            course.id = editing.id
            dataManager.updateCourse(course)
        } else {
            // 添加模式：由 DataManager 统一追加（内存为准 + 唯一 id），
            // 修复之前"从磁盘重读旧数据再覆盖保存"导致的新课程挤掉旧课程问题
            dataManager.addCourse(course)
            // 成就检查：添加第一门课程（dismiss 后无法弹 toast，静默解锁，成就墙可见）
            AchievementManager.unlockIfNeeded("course_adder")
        }

        dismiss()
    }

    /// 跳转系统地图搜索教室位置（Apple 地图通用链接，未装地图 App 时打开网页版）
    private func openInMaps() {
        let query = location.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "maps.apple.com/?q=\(encoded)") else { return }
        UIApplication.shared.open(url)
    }

    /// 把 Date 格式化为 "HH:mm" 字符串
    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    /// 把 "HH:mm" 字符串解析为 Date（当天时刻，解析失败返回 nil）
    private static func parseTime(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.date(from: text)
    }
}
