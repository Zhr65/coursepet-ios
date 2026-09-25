// MARK: - 设置视图（对应 prototype/js/ui/settings.js）
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var dataManager: DataManager
    @State private var petName: String = "小火人"
    @State private var semesterStartDate: String = ""
    @State private var animSpeed: AppSettings.AnimSpeed = .mid
    @State private var charId: String = "char1"
    @State private var darkMode: Bool = false
    @State private var simLowBattery: Bool = false
    @State private var simCharging: Bool = false
    @State private var simMusic: Bool = false
    @State private var bgMode: BackgroundSetting.BGMode = .default
    @State private var backgroundColorName: String = "默认灰"
    @State private var reminderEnabled: Bool = false
    @State private var showResetConfirm = false

    var body: some View {
        List {
            // ── 基础设置 ──
            Section("📅 基础") {
                TextField("宠物名字", text: $petName)
                    .textContentType(.name)
                DatePicker(
                    "学期开始日期",
                    selection: Binding(
                        get: { dateFromString() ?? Date() },
                        set: { semesterStartDate = formatToDate($0) }
                    ),
                    displayedComponents: .date
                )
                .onChange(of: semesterStartDate) { _ in
                    // 自动保存
                    saveSettings()
                }
            }

            // ── 宠物设置 ──
            Section("🐾 宠物") {
                Picker("动画速度", selection: $animSpeed) {
                    Text("🐢 慢").tag(AppSettings.AnimSpeed.slow)
                    Text("🐾 中").tag(AppSettings.AnimSpeed.mid)
                    Text("⚡ 快").tag(AppSettings.AnimSpeed.fast)
                }
                Picker("宠物形象", selection: $charId) {
                    ForEach(["char1", "char2", "char3", "char4"], id: \.self) { id in
                        Text("角色 \(id.last!)").tag(id)
                    }
                }
            }

            // ── 系统状态模拟（开发期用） ──
            Section("🔧 状态模拟") {
                Toggle("🔋 模拟电量低 (<20%)", isOn: $simLowBattery)
                Toggle("⚡ 模拟充电中", isOn: $simCharging)
                Toggle("🎵 模拟播放音乐", isOn: $simMusic)
            }

            // ── 提醒 ──
            Section("🔔 提醒") {
                Toggle("上课提醒（提前 15 分钟）", isOn: $reminderEnabled)
            }

            // ── 显示 ──
            Section("🎨 显示") {
                Toggle("深色模式", isOn: $darkMode)
            }

            // ── 背景主题 ──
            Section("🌈 背景主题") {
                HStack(spacing: 0) {
                    ForEach(BackgroundTheme.all) { theme in
                        themeCard(theme)
                    }
                }
                Text("当前主题：\(backgroundColorName)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // ── 危险操作 ──
            Section {
                Button(role: .destructive) {
                    showResetConfirm = true
                } label: {
                    HStack {
                        Image(systemName: "trash.fill")
                        Text("清空全部数据")
                            .foregroundColor(.red)
                    }
                }
            }
        }
        .listStyle(InsetGroupedListStyle())
        .navigationTitle("设置")
        .alert("确认清空", isPresented: $showResetConfirm) {
            Button("取消", role: .cancel) {}
            Button("清空", role: .destructive) { resetAll() }
        } message: {
            Text("确定要清空全部数据吗？课表、宠物进度和设置都将被清除，此操作不可撤销。")
        }
        .onAppear { loadSettings() }
        .onChange(of: animSpeed) { _ in saveSettings() }
        .onChange(of: charId) { _ in saveSettings() }
        .onChange(of: darkMode) { _ in saveSettings() }
        .onChange(of: simLowBattery) { _ in saveSettings() }
        .onChange(of: simCharging) { _ in saveSettings() }
        .onChange(of: simMusic) { _ in saveSettings() }
        .onChange(of: reminderEnabled) { _ in
            // 保存开关状态（saveState 会经钩子触发一次 refreshAll）
            saveSettings()
            if reminderEnabled {
                // 打开提醒：先申请通知授权，授权流程结束后再重建通知
                NotificationManager.requestAuthorization { _ in
                    NotificationManager.refreshAll()
                }
            } else {
                // 关闭提醒：refreshAll 会清空全部已调度的课程提醒且不再重建
                NotificationManager.refreshAll()
            }
        }
    }

    // MARK: - 背景主题色卡
    private func themeCard(_ theme: BackgroundTheme) -> some View {
        let isSelected = backgroundColorName == theme.name
        return Button {
            // 选中后立即写入（DataManager 内部会触发界面刷新）
            backgroundColorName = theme.name
            dataManager.setBackgroundColorName(theme.name)
        } label: {
            VStack(spacing: 4) {
                Circle()
                    .fill(LinearGradient(colors: theme.colors, startPoint: .top, endPoint: .bottom))
                    .frame(width: 44, height: 44)
                    .overlay(
                        Circle().stroke(
                            isSelected ? Color.indigo : Color.clear,
                            lineWidth: 3
                        )
                    )
                Text(theme.name)
                    .font(.caption2)
                    .foregroundColor(isSelected ? .indigo : .secondary)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }

    // MARK: - 读取设置
    private func loadSettings() {
        let state = dataManager.loadState()
        petName = state.pet.name
        semesterStartDate = state.semester.startDate
        animSpeed = state.settings.animSpeed
        charId = state.settings.charId
        darkMode = state.settings.darkMode
        simLowBattery = state.settings.simLowBattery
        simCharging = state.settings.simCharging
        simMusic = state.settings.simMusic
        bgMode = state.settings.bg.mode
        backgroundColorName = dataManager.backgroundColorName
        reminderEnabled = state.settings.reminderEnabled
    }

    // MARK: - 保存设置
    private func saveSettings() {
        var s = dataManager.loadState()
        s.pet.name = petName.isEmpty ? "小火人" : petName
        s.semester.startDate = semesterStartDate
        s.settings.animSpeed = animSpeed
        s.settings.charId = charId
        s.settings.darkMode = darkMode
        s.settings.simLowBattery = simLowBattery
        s.settings.simCharging = simCharging
        s.settings.simMusic = simMusic
        s.settings.bg.mode = bgMode
        s.settings.reminderEnabled = reminderEnabled
        // saveState 内部会同步 @Published 镜像属性，深色模式等设置立即生效
        dataManager.saveState(s)
    }

    private func resetAll() {
        var s = AppState.default
        s.semester.startDate = semesterStartDate
        dataManager.saveState(s)
        // 一并重置每日签到记录
        dataManager.setCheckInStreak(0)
        dataManager.setLastCheckInDate(Date(timeIntervalSince1970: 0))
        dataManager.setBackgroundColorName("默认灰")
        petName = "小火人"
        backgroundColorName = "默认灰"
        showToast("已清空全部数据")
    }

    private func dateFromString() -> Date? {
        guard !semesterStartDate.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: semesterStartDate)
    }

    private func formatToDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private func showToast(_ message: String) {
        // 使用 DispatchQueue 在主线程显示
        DispatchQueue.main.async {
            // 实际可用 Toast 视图，此处简化
        }
    }
}

// MARK: - 背景主题预设（SettingsView 与 ScheduleView 共用）
struct BackgroundTheme: Identifiable {
    let name: String
    let colors: [Color]
    var id: String { name }

    static let all: [BackgroundTheme] = [
        BackgroundTheme(name: "晨雾蓝", colors: [
            Color(red: 0.78, green: 0.87, blue: 0.98),
            Color(red: 0.60, green: 0.75, blue: 0.95)
        ]),
        BackgroundTheme(name: "樱花粉", colors: [
            Color(red: 0.99, green: 0.87, blue: 0.90),
            Color(red: 0.98, green: 0.74, blue: 0.81)
        ]),
        BackgroundTheme(name: "薄荷绿", colors: [
            Color(red: 0.82, green: 0.95, blue: 0.89),
            Color(red: 0.61, green: 0.87, blue: 0.77)
        ]),
        BackgroundTheme(name: "暖阳橙", colors: [
            Color(red: 1.00, green: 0.90, blue: 0.78),
            Color(red: 1.00, green: 0.75, blue: 0.57)
        ]),
        BackgroundTheme(name: "默认灰", colors: [
            Color(.systemGray6),
            Color(.systemGray4)
        ])
    ]

    /// 按名称取主题，找不到时兜底"默认灰"
    static func named(_ name: String) -> BackgroundTheme {
        return all.first { $0.name == name } ?? all[4]
    }
}
