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
                .onChange(of: semesterStartDate) { newValue in
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

            // ── 显示 ──
            Section("🎨 显示") {
                Toggle("深色模式", isOn: $darkMode)
                .onChange(of: darkMode) { _ in saveSettings() }
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
        dataManager.saveState(s)
        // 更新深色模式
        if UIApplication.shared.windows.first != nil {
            // 触发 UI 更新
        }
    }

    private func resetAll() {
        var s = AppState.default
        s.semester.startDate = semesterStartDate
        dataManager.saveState(s)
        petName = "小火人"
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
