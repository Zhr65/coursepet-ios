// MARK: - 拍照识课表：预制缩小版预览 + 逐课放大确认
// 流程：识别成功 → 预制网格缩略图（bottom sheet）→ 点某格弹出完整表单 → 改完/确认 → 批量入 DataManager
import SwiftUI

struct CourseImportConfirmView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var dataManager: DataManager

    /// 原始识别结果（预制态，用户编辑后会更新）
    @State private var courses: [Course]
    /// 原始照片（用户可以对照着看）
    let originalImage: UIImage
    /// 识别结果：原始 JSON 可能有错，这里让用户编辑确认
    @State private var editingCourse: Course?
    /// 正在识别 / 识别失败
    let isLoading: Bool
    let errorMessage: String?
    /// 点击「重新识别」→ 上层重新跑 Vision
    let onRetry: (() -> Void)?

    init(courses: [Course], originalImage: UIImage, isLoading: Bool = false, errorMessage: String? = nil, onRetry: (() -> Void)? = nil) {
        _courses = State(initialValue: courses)
        self.originalImage = originalImage
        self.isLoading = isLoading
        self.errorMessage = errorMessage
        self.onRetry = onRetry
    }

    private let dayShort = ["一", "二", "三", "四", "五", "六", "日"]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // ── 顶部信息栏 ──
                headerBar

                if isLoading {
                    Spacer()
                    ProgressView("正在识别课表…")
                    Spacer()
                } else if let errorMessage {
                    Spacer()
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 40))
                            .foregroundColor(.orange)
                        Text(errorMessage)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                        if let onRetry {
                            Button("重新识别") { onRetry() }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                    .padding()
                    Spacer()
                } else if courses.isEmpty {
                    Spacer()
                    VStack(spacing: 12) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 40))
                            .foregroundColor(.gray)
                        Text("没识别到课程")
                            .foregroundColor(.secondary)
                        Text("试试拍清楚一点，或者换张图")
                            .font(.caption)
                            .foregroundColor(Color(.tertiaryLabel))
                        if let onRetry {
                            Button("重新识别") { onRetry() }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                    .padding()
                    Spacer()
                } else {
                    // ── 预制网格缩略图 ──
                    courseGrid
                }

                // ── 底部操作栏 ──
                if !isLoading && errorMessage == nil && !courses.isEmpty {
                    bottomBar
                }
            }
            .navigationTitle("识别结果")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            // 点击某门课弹出完整编辑表单
            .sheet(item: $editingCourse) { course in
                CourseEditInImportSheet(
                    course: course,
                    originalImage: originalImage,
                    onSave: { updated in
                        if let idx = courses.firstIndex(where: { $0.id == updated.id }) {
                            courses[idx] = updated
                        }
                        editingCourse = nil
                    },
                    onDelete: { target in
                        courses.removeAll { $0.id == target.id }
                        editingCourse = nil
                    }
                )
            }
        }
    }

    // MARK: - 顶部信息栏

    private var headerBar: some View {
        HStack(spacing: 12) {
            // 原图缩略图（点击可全屏查看）
            Button {
                // 点原图 → 预览大图（纯看，不能互动）
            } label: {
                Image(uiImage: originalImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.gray.opacity(0.3), lineWidth: 0.5)
                    )
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(isLoading ? "正在识别…" : "识别到 \(courses.count) 门课")
                    .font(.headline)
                Text("点每格可修改时间/星期/教室")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()

            if !isLoading && courses.isEmpty, let onRetry {
                Button { onRetry() } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - 预制网格缩略图

    private var courseGrid: some View {
        ScrollView {
            VStack(spacing: 4) {
                // 星期表头
                HStack(spacing: 2) {
                    ForEach(0..<7, id: \.self) { idx in
                        Text(dayShort[idx])
                            .font(.caption2)
                            .frame(maxWidth: .infinity)
                            .foregroundColor(.secondary)
                    }
                }
                // 5 行节次（按咱固定作息）
                ForEach(0..<5, id: \.self) { row in
                    HStack(spacing: 2) {
                        ForEach(0..<7, id: \.self) { col in
                            // 从 courses 里找当天该节的课
                            let day = col + 1
                            let period = row + 1
                            let matched = courses.first { courseInPeriod($0, day: day, period: period) }

                            Group {
                                if let course = matched {
                                    courseThumbnail(course)
                                } else {
                                    Color.clear
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
        }
    }

    /// 判断一门课是否落在某天某节
    private func courseInPeriod(_ course: Course, day: Int, period: Int) -> Bool {
        guard course.dayOfWeek == day else { return false }
        let periods = periodRange(for: course)
        return periods.contains(period)
    }

    /// 一门课跨几节（基于咱固定作息）
    private func periodRange(for course: Course) -> ClosedRange<Int> {
        let schedule: [Int: (Int, Int)] = [
            1: (10 * 60, 11 * 60 + 40),
            2: (12 * 60, 13 * 60 + 40),
            3: (16 * 60, 17 * 60 + 40),
            4: (18 * 60, 19 * 60 + 40),
            5: (20 * 60 + 30, 22 * 60),
        ]
        let startMin = ScheduleHelpers.timeToMinutes(course.startTime) ?? 0
        let endMin = ScheduleHelpers.timeToMinutes(course.endTime) ?? startMin + 60
        var startP = 1, endP = 1
        for (p, (s, e)) in schedule where startMin >= s { startP = p }
        for (p, (s, e)) in schedule where endMin > s { endP = p }
        return startP...max(startP, endP)
    }

    /// 单门课缩略格（点击弹出完整表单）
    private func courseThumbnail(_ course: Course) -> some View {
        Button {
            editingCourse = course
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(course.name)
                    .font(.caption2)
                    .fontWeight(.medium)
                    .lineLimit(1)
                if !course.location.isEmpty {
                    Text(course.location)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(hex: course.color) ?? Color.pink.opacity(0.3))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.primary.opacity(0.1), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - 底部操作栏

    private var bottomBar: some View {
        HStack(spacing: 12) {
            Button {
                // 加一门新课
                let newCourse = Course(name: "", dayOfWeek: 1, startTime: "10:00", endTime: "11:40")
                editingCourse = newCourse
            } label: {
                Image(systemName: "plus.circle")
                    .font(.title2)
            }
            .buttonStyle(.plain)

            Spacer()

            Button {
                dismiss()
            } label: {
                Text("取消")
                    .foregroundColor(.secondary)
            }

            Button {
                DataManager.shared.appendCourses(courses)
                dismiss()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                    Text("导入 \(courses.count) 门课")
                        .fontWeight(.semibold)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(Color.indigo.opacity(0.9), in: Capsule())
                .foregroundColor(.white)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
    }
}

// MARK: - 预制态逐课编辑 Sheet（复用 AddCourseView 的 Form 结构）

struct CourseEditInImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    let course: Course
    let originalImage: UIImage
    let onSave: (Course) -> Void
    let onDelete: (Course) -> Void

    // 表单状态
    @State private var courseName: String
    @State private var teacher: String
    @State private var location: String
    @State private var dayOfWeek: Int
    @State private var startTime: Date
    @State private var endTime: Date
    @State private var startWeek: Int
    @State private var endWeek: Int
    @State private var weekParity: WeekParity

    private let dayOptions = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]

    init(course: Course, originalImage: UIImage, onSave: @escaping (Course) -> Void, onDelete: @escaping (Course) -> Void) {
        self.course = course
        self.originalImage = originalImage
        self.onSave = onSave
        self.onDelete = onDelete

        _courseName = State(initialValue: course.name)
        _teacher = State(initialValue: course.teacher)
        _location = State(initialValue: course.location)
        _dayOfWeek = State(initialValue: course.dayOfWeek)
        _startTime = State(initialValue: Self.parseTime(course.startTime))
        _endTime = State(initialValue: Self.parseTime(course.endTime))
        _startWeek = State(initialValue: course.startWeek)
        _endWeek = State(initialValue: course.endWeek)
        _weekParity = State(initialValue: course.weekParity)
    }

    private static func parseTime(_ t: String) -> Date {
        let cal = Calendar.current
        let now = Date()
        let defaultStart = cal.date(bySettingHour: 10, minute: 0, second: 0, of: now) ?? now
        let parts = t.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return defaultStart }
        return cal.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: now) ?? defaultStart
    }

    var body: some View {
        NavigationStack {
            Form {
                // 原图对照
                Section("原图对照") {
                    Image(uiImage: originalImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 180)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                Section("课程信息") {
                    TextField("课程名", text: $courseName)
                    TextField("教师（选填）", text: $teacher)
                    TextField("地点（选填）", text: $location)
                }

                Section("上课时间") {
                    Picker("星期", selection: $dayOfWeek) {
                        ForEach(1...7, id: \.self) { Text(dayOptions[$0 - 1]).tag($0) }
                    }
                    DatePicker("开始时间", selection: $startTime, displayedComponents: .hourAndMinute)
                    DatePicker("结束时间", selection: $endTime, displayedComponents: .hourAndMinute)
                }

                Section("周次") {
                    Stepper("起始周：\(startWeek)", value: $startWeek, in: 1...30)
                    Stepper("结束周：\(endWeek)", value: $endWeek, in: startWeek...30)
                    Picker("单双周", selection: $weekParity) {
                        Text("每周").tag(WeekParity.both)
                        Text("单周").tag(WeekParity.single)
                        Text("双周").tag(WeekParity.double)
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    Button(role: .destructive) {
                        onDelete(course)
                    } label: {
                        HStack { Spacer(); Text("删除这门课"); Spacer() }
                    }
                }
            }
            .navigationTitle("修改课程")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        let f = DateFormatter()
                        f.dateFormat = "HH:mm"
                        let updated = Course(
                            id: course.id,   // 保留原 id（预制态定位用）
                            name: courseName.isEmpty ? course.name : courseName,
                            teacher: teacher,
                            location: location,
                            dayOfWeek: dayOfWeek,
                            startTime: f.string(from: startTime),
                            endTime: f.string(from: endTime),
                            startWeek: startWeek,
                            endWeek: max(startWeek, endWeek),
                            weekParity: weekParity,
                            color: course.color.isEmpty ? CourseColorPalette.color(forDay: dayOfWeek) : course.color
                        )
                        onSave(updated)
                    }
                    .disabled(courseName.isEmpty)
                }
            }
        }
    }
}
