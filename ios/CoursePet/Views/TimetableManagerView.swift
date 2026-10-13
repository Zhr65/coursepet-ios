// MARK: - 多课程表管理视图（设置页与课表页菜单共用）
// 列出全部课表，可新建 / 切换 / 重命名 / 删除；删除为非活动表或非最后一张时直接删，
// 否则给出确认（防止误删全部课表）。
import SwiftUI

struct TimetableManagerView: View {
    @ObservedObject var dm: DataManager = .shared
    @Environment(\.dismiss) private var dismiss

    @State private var showCreate = false
    @State private var newName = ""
    @State private var newStartDate: Date = Date()
    @State private var copyFromActive = false
    @State private var renamingTable: Timetable?
    @State private var renameText = ""
    @State private var pendingDelete: Timetable?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(dm.timetables.sorted(by: { $0.createdAt < $1.createdAt })) { table in
                        HStack(spacing: 12) {
                            // 当前激活表的视觉标记
                            Image(systemName: table.id == dm.activeTimetableId
                                  ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(table.id == dm.activeTimetableId ? Color.accentColor : Color.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(table.name).font(.body).lineLimit(1)
                                HStack(spacing: 8) {
                                    Label("\(table.courses.count) 节", systemImage: "book")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    Label(formatDateLabel(table.startDate), systemImage: "calendar")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            // 切换按钮（不是活动表才显示）
                            if table.id != dm.activeTimetableId {
                                Button("切换") { switchTo(table) }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                            } else {
                                Text("当前")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if table.id != dm.activeTimetableId { switchTo(table) }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                pendingDelete = table
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                            Button {
                                renamingTable = table
                                renameText = table.name
                            } label: {
                                Label("重命名", systemImage: "pencil")
                            }
                            .tint(.blue)
                        }
                    }
                } header: {
                    Text("已建课程表（\(dm.timetables.count)）")
                } footer: {
                    Text("不同学期的课程独立保存。删除最后一张将被阻止。切换后左侧栏会重新加载该学期的全部课程。")
                        .font(.caption2)
                }

                Section {
                    Button {
                        newName = ""
                        newStartDate = parseDateOrToday(dm.semesterStartDate)
                        copyFromActive = false
                        showCreate = true
                    } label: {
                        Label("新建课程表", systemImage: "plus.circle.fill")
                    }
                }
            }
            .navigationTitle("课程表管理")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        // 新建弹窗
        .sheet(isPresented: $showCreate) {
            NavigationStack {
                Form {
                    Section("课程表名") {
                        TextField("如：2025 秋季", text: $newName)
                            .textInputAutocapitalization(.never)
                    }
                    Section("开学日期") {
                        DatePicker(
                            "开学日期",
                            selection: $newStartDate,
                            displayedComponents: [.date]
                        )
                    }
                    Section {
                        Toggle("复制当前课程作为初始", isOn: $copyFromActive)
                    } footer: {
                        Text("勾选则把当前活动课程表里的课程全部复制到新表里（适合学期交替时复用模板）。")
                    }
                }
                .navigationTitle("新建课程表")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { showCreate = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("创建") {
                            let formatter = DateFormatter()
                            formatter.dateFormat = "yyyy-MM-dd"
                            _ = dm.createTimetable(
                                name: newName,
                                startDate: formatter.string(from: newStartDate),
                                copyCoursesFromActive: copyFromActive
                            )
                            showCreate = false
                        }
                        .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
        // 重命名弹窗
        .alert("重命名", isPresented: Binding(
            get: { renamingTable != nil },
            set: { if !$0 { renamingTable = nil } }
        )) {
            TextField("课程表名", text: $renameText)
            Button("取消", role: .cancel) { renamingTable = nil }
            Button("保存") {
                if let t = renamingTable {
                    dm.renameTimetable(id: t.id, name: renameText)
                }
                renamingTable = nil
            }
        }
        // 删除确认（最后一张也允许，但要二次确认）
        .alert("删除课程表", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )) {
            Button("取消", role: .cancel) { pendingDelete = nil }
            Button("删除", role: .destructive) {
                if let t = pendingDelete { dm.deleteTimetable(id: t.id) }
                pendingDelete = nil
            }
        } message: {
            if let t = pendingDelete {
                Text("将永久删除「\(t.name)」（共 \(t.courses.count) 节课程），不可恢复。")
            }
        }
    }

    // MARK: - Actions
    private func switchTo(_ table: Timetable) {
        dm.switchTimetable(to: table.id)
    }

    private func formatDateLabel(_ s: String) -> String {
        // "YYYY-MM-DD" -> "MM-DD"；空字符串显示"—"
        guard s.count >= 10 else { return "—" }
        let start = s.index(s.startIndex, offsetBy: 5)
        let end = s.index(s.startIndex, offsetBy: 10)
        return String(s[start..<end])
    }

    private func parseDateOrToday(_ s: String) -> Date {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.date(from: s) ?? Date()
    }
}