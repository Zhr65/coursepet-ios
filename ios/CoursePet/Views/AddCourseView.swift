// MARK: - 手动添加课程表单
import SwiftUI

struct AddCourseView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var dataManager: DataManager

    // MARK: - 表单状态
    @State private var courseName: String = ""
    @State private var teacher: String = ""
    @State private var location: String = ""
    @State private var dayOfWeek: Int = 1
    @State private var startTime: Date = Calendar.current.date(bySettingHour: 8, minute: 0, of: Date()) ?? Date()
    @State private var endTime: Date = Calendar.current.date(bySettingHour: 9, minute: 40, of: Date()) ?? Date()
    @State private var startWeek: Int = 1
    @State private var endWeek: Int = 20
    @State private var weekParity: WeekParity = .both
    // 校验错误提示
    @State private var errorMessage: String?

    private let dayOptions = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]

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

                // ── 保存 ──
                Section {
                    Button {
                        saveCourse()
                    } label: {
                        Text("保存课程")
                            .font(.headline)
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                            .foregroundColor(.indigo)
                    }
                }
            }
            .navigationTitle("添加课程")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { dismiss() }
                }
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
        let course = Course(
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
        // 追加到课程列表并持久化（saveState 内部会触发界面刷新）
        var state = dataManager.loadState()
        state.courses.append(course)
        dataManager.saveState(state)
        dismiss()
    }

    /// 把 Date 格式化为 "HH:mm" 字符串
    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}
