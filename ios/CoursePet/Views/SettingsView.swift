// MARK: - 设置视图（所有控件直接绑定 DataManager，切 tab / 重启后状态不丢失）
// 修复：旧实现用本地 @State 初值 + onAppear 重置，导致切 tab 回来恢复原样、开关"无效"；
// 现在每个 Toggle/Picker 都通过 dmBinding 读写 DataManager 并立即持久化。
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var dataManager: DataManager
    @State private var showResetConfirm = false

    var body: some View {
        ZStack {
            // 柔和渐变背景：玻璃行透出背景色
            LinearGradient(colors: PagePalette.settings, startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()

            List {
                // ── 顶部大标题 ──
                Section {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("设置")
                            .font(.title)
                            .fontWeight(.bold)
                        Text("个性化你的课表与宠物")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                    .listRowBackground(Color.clear)
                }

                // ── 基础设置 ──
                Section(header: Text("📅 基础")) {
                    Group {
                        TextField("宠物名字", text: nameBinding)
                        DatePicker(
                            "学期开始日期",
                            selection: semesterBinding,
                            displayedComponents: .date
                        )
                    }
                    .glassListRow()
                }

                // ── 宠物设置（带实时预览） ──
                Section(header: Text("🐾 宠物")) {
                    Group {
                        // 实时预览小宠物：改形象/速度立刻变化
                        // 用 PetAnimationView 读取已安装的 PNG 帧图，预览与真机显示一致
                        HStack {
                            Spacer()
                            VStack(spacing: 6) {
                                PetAnimationView(
                                    action: "idle",
                                    charId: dataManager.charId,
                                    speed: dataManager.animSpeed,
                                    size: 90
                                )
                                .id("preview-\(dataManager.charId)-\(dataManager.animSpeed)")
                                Text("形象预览（改动立即生效）")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                        }
                        Picker("宠物形象", selection: dmBinding(\.charId)) {
                            Text("角色 1 · 小狼").tag("char1")
                            Text("角色 2 · 猪护士").tag("char2")
                            Text("角色 3 · 小青蛙").tag("char3")
                            Text("角色 4 · 小猫咪").tag("char4")
                        }
                        Picker("动画速度", selection: dmBinding(\.animSpeed)) {
                            Text("🐢 慢").tag(AppSettings.AnimSpeed.slow)
                            Text("🐾 中").tag(AppSettings.AnimSpeed.mid)
                            Text("⚡ 快").tag(AppSettings.AnimSpeed.fast)
                        }
                    }
                    .glassListRow()
                }

                // ── 系统状态模拟（开发期用） ──
                Section(header: Text("🔧 状态模拟")) {
                    Group {
                        Toggle("🔋 模拟电量低 (<20%)", isOn: dmBinding(\.simLowBattery))
                        Toggle("⚡ 模拟充电中", isOn: dmBinding(\.simCharging))
                        Toggle("🎵 模拟播放音乐", isOn: dmBinding(\.simMusic))
                    }
                    .glassListRow()
                }

                // ── 提醒 ──
                Section(header: Text("🔔 提醒")) {
                    Group {
                        Toggle("上课提醒（提前 15 分钟）", isOn: reminderBinding)
                    }
                    .glassListRow()
                }

                // ── 显示 ──
                Section(header: Text("🎨 显示")) {
                    Group {
                        Toggle("深色模式", isOn: dmBinding(\.darkMode))
                    }
                    .glassListRow()
                }

                // ── 背景主题 ──
                Section(header: Text("🌈 背景主题")) {
                    Group {
                        HStack(spacing: 0) {
                            ForEach(BackgroundTheme.all) { theme in
                                themeCard(theme)
                            }
                        }
                        Text("当前主题：\(dataManager.backgroundColorName)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .glassListRow()
                }

                // ── 危险操作 ──
                Section(header: Text("⚠️ 危险操作")) {
                    Group {
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
                    .glassListRow()
                }
            }
            .listStyle(InsetGroupedListStyle())
            .scrollContentBackground(.hidden)
        }
        .onAppear {
            // 兼容旧数据：charId 不在四种预设里时归一为 char1
            if !["char1", "char2", "char3", "char4"].contains(dataManager.charId) {
                dataManager.charId = "char1"
                dataManager.savePublishedState()
            }
        }
        .alert("确认清空", isPresented: $showResetConfirm) {
            Button("取消", role: .cancel) {}
            Button("清空", role: .destructive) { resetAll() }
        } message: {
            Text("确定要清空全部数据吗？课表、宠物进度和设置都将被清除，此操作不可撤销。")
        }
    }

    // MARK: - DataManager 直绑 Binding
    /// 生成直接读写 DataManager @Published 属性的 Binding：
    /// set 时先写内存镜像（立即触发界面刷新），再整体落盘。
    private func dmBinding<T>(_ keyPath: ReferenceWritableKeyPath<DataManager, T>) -> Binding<T> {
        Binding(
            get: { dataManager[keyPath: keyPath] },
            set: { newValue in
                dataManager[keyPath: keyPath] = newValue
                dataManager.savePublishedState()
            }
        )
    }

    /// 宠物名字：每输入一个字符都轻量落盘（triggerHook=false，不重建通知）
    private var nameBinding: Binding<String> {
        Binding(
            get: { dataManager.petName },
            set: { dataManager.petName = $0; dataManager.savePublishedState(triggerHook: false) }
        )
    }

    /// 学期开始日期：字符串 "yyyy-MM-dd" 与 Date 互转
    private var semesterBinding: Binding<Date> {
        Binding(
            get: {
                guard !dataManager.semesterStartDate.isEmpty else { return Date() }
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd"
                return formatter.date(from: dataManager.semesterStartDate) ?? Date()
            },
            set: {
                dataManager.semesterStartDate = WeekMath.formatDate($0)
                dataManager.savePublishedState()
            }
        )
    }

    /// 上课提醒开关：切换后申请授权并重建/清空通知
    private var reminderBinding: Binding<Bool> {
        Binding(
            get: { dataManager.reminderEnabled },
            set: { enabled in
                dataManager.reminderEnabled = enabled
                dataManager.savePublishedState()
                if enabled {
                    // 打开提醒：先申请通知授权，授权流程结束后再重建通知
                    NotificationManager.requestAuthorization { _ in
                        NotificationManager.refreshAll()
                    }
                } else {
                    // 关闭提醒：refreshAll 会清空全部已调度的课程提醒且不再重建
                    NotificationManager.refreshAll()
                }
            }
        )
    }

    // MARK: - 背景主题色卡
    private func themeCard(_ theme: BackgroundTheme) -> some View {
        let isSelected = dataManager.backgroundColorName == theme.name
        return Button {
            // 选中后立即写入（DataManager 内部会触发界面刷新）
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

    // MARK: - 清空全部数据
    private func resetAll() {
        dataManager.saveState(AppState.default)
        // 一并重置每日签到记录、背景主题与等级经验
        dataManager.setCheckInStreak(0)
        dataManager.setLastCheckInDate(Date(timeIntervalSince1970: 0))
        dataManager.setBackgroundColorName("默认灰")
        dataManager.resetLevelExp()
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
