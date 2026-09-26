// MARK: - 设置视图（所有控件直接绑定 DataManager，切 tab / 重启后状态不丢失）
// 修复：旧实现用本地 @State 初值 + onAppear 重置，导致切 tab 回来恢复原样、开关"无效"；
// 现在每个 Toggle/Picker 都通过 dmBinding 读写 DataManager 并立即持久化。
import SwiftUI
import UniformTypeIdentifiers
import UIKit
import ActivityKit
// ShortcutsLink（Siri 快捷指令入口）由 AppIntents 框架提供
import AppIntents

struct SettingsView: View {
    @EnvironmentObject var dataManager: DataManager
    @State private var showResetConfirm = false
    // 数据备份
    @State private var shareURL: URL?
    @State private var showImporter = false
    @State private var restoreResultAlert: String?
    // 灵动岛诊断面板文本（进入设置页或点按钮时刷新）
    @State private var diagnosticText = "（打开设置页时刷新）"

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
                        // 宠物形象商店（3 列网格：解锁的可选，锁定的显示条件与进度）
                        petShopGrid
                            .padding(.vertical, 4)
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
                        Toggle("DDL 轰炸（截止三连催）", isOn: ddlBombBinding)
                        Toggle("天气早安播报（每天 07:00）", isOn: weatherBinding)
                        Text("DDL 轰炸：截止前一天 20:00 / 当天 08:00 / 当天 18:00 各提醒一次")
                            .font(.caption)
                            .foregroundColor(.secondary)
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

                // ── 灵动岛诊断（无 Mac 环境的远程排障面板）──
                Section(header: Text("🧪 灵动岛诊断")) {
                    Group {
                        let enabled = ActivityAuthorizationInfo().areActivitiesEnabled
                        Label(
                            enabled ? "系统实时活动权限：已开启" : "系统实时活动权限：未开启（去 系统设置→CoursePet 打开）",
                            systemImage: enabled ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"
                        )
                        .foregroundColor(enabled ? .green : .red)
                        .font(.caption)
                        Text(diagnosticText)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(12)
                        HStack {
                            Button("重新检查") {
                                LADebug.log("—— 手动触发检查 ——")
                                LiveActivityManager.checkAndStartIfNeeded()
                                diagnosticText = LADebug.text()
                            }
                            .font(.caption)
                            Spacer()
                            Button("清空日志") {
                                LADebug.clear()
                                diagnosticText = "（已清空）"
                            }
                            .font(.caption)
                        }
                    }
                    .glassListRow()
                }

                // ── Siri 快捷指令 ──
                Section(header: Text("🗣️ Siri 快捷指令")) {
                    Group {
                        ShortcutsLink()
                        Text("支持对 Siri 说「今天有什么课」「记待办」「记一笔花销」，也可在快捷指令 App 里组合自动化")
                            .font(.caption)
                            .foregroundColor(.secondary)
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

                // ── 数据备份 ──
                Section(header: Text("💾 数据备份"), footer: Text("免费签名 7 天过期，重装 App 前先导出备份；换机也可以用备份迁移全部数据。")) {
                    Group {
                        // 存储模式诊断：App Group 权限无效时数据走本地沙盒（仍持久，仅小组件不共享）
                        HStack(spacing: 8) {
                            Image(systemName: StorageLocation.usesAppGroup ? "sharedwithyou" : "internaldrive.fill")
                                .foregroundColor(StorageLocation.usesAppGroup ? .green : .orange)
                            Text(StorageLocation.usesAppGroup
                                 ? "存储正常 · 与小组件共享"
                                 : "本地存储 · 数据可持久（小组件不共享）")
                                .font(.subheadline)
                        }
                        Button {
                            exportBackup()
                        } label: {
                            HStack {
                                Image(systemName: "square.and.arrow.up.fill")
                                Text("导出备份文件")
                            }
                        }
                        Button {
                            showImporter = true
                        } label: {
                            HStack {
                                Image(systemName: "square.and.arrow.down.fill")
                                Text("从文件导入恢复")
                            }
                        }
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
                .onAppear { diagnosticText = LADebug.text() }
        }
        .onAppear {
            // 兼容旧数据：charId 不在九种预设里时归一为 char1
            if PetCatalog.character(id: dataManager.charId) == nil {
                dataManager.charId = "char1"
            }
            dataManager.savePublishedState()
        }
        .alert("确认清空", isPresented: $showResetConfirm) {
            Button("取消", role: .cancel) {}
            Button("清空", role: .destructive) { resetAll() }
        } message: {
            Text("确定要清空全部数据吗？课表、宠物进度和设置都将被清除，此操作不可撤销。")
        }
        // 备份文件分享（存到"文件"或发微信/AirDrop 都行）
        .sheet(isPresented: Binding(
            get: { shareURL != nil },
            set: { if !$0 { shareURL = nil } }
        )) {
            if let url = shareURL {
                ActivityShareSheet(items: [url])
            }
        }
        // 从"文件"选择备份导入
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            handleImport(result)
        }
        .alert("恢复结果", isPresented: Binding(
            get: { restoreResultAlert != nil },
            set: { if !$0 { restoreResultAlert = nil } }
        )) {
            Button("好的", role: .cancel) {}
        } message: {
            Text(restoreResultAlert ?? "")
        }
    }

    // MARK: - 宠物形象商店
    /// 当前解锁进度数据快照
    private var focusMinutesNow: Int {
        FocusStore.shared.totalSummary().totalMinutes
    }

    /// 形象商店网格：解锁的可点击使用；锁定的灰色剪影 + 🔒 + 条件 + 进度条
    private var petShopGrid: some View {
        let focusMinutes = focusMinutesNow
        let streak = dataManager.getCheckInStreak()
        let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)

        return LazyVGrid(columns: columns, spacing: 10) {
            ForEach(PetCatalog.all) { ch in
                let unlocked = ch.isUnlocked(
                    level: dataManager.petLevel,
                    focusMinutes: focusMinutes,
                    streak: streak
                )
                let isSelected = dataManager.charId == ch.id

                Button {
                    guard unlocked else { return }
                    dataManager.charId = ch.id
                    dataManager.savePublishedState()
                } label: {
                    VStack(spacing: 4) {
                        ZStack(alignment: .topTrailing) {
                            // 预览图（Bundle 内 pet_idle_0）
                            Group {
                                if let img = Self.shopPreviewImage(ch.id) {
                                    Image(uiImage: img).resizable().scaledToFit()
                                } else {
                                    Color.gray.opacity(0.15)
                                }
                            }
                            .frame(width: 64, height: 64)
                            .saturation(unlocked ? 1 : 0)
                            .opacity(unlocked ? 1 : 0.35)

                            if !unlocked {
                                Image(systemName: "lock.fill")
                                    .font(.caption2)
                                    .foregroundColor(.white)
                                    .padding(4)
                                    .background(Circle().fill(Color.black.opacity(0.55)))
                                    .offset(x: 4, y: -4)
                            }
                        }
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(isSelected ? Color.indigo : Color.clear, lineWidth: 2.5)
                        )

                        Text(ch.name)
                            .font(.caption2)
                            .fontWeight(isSelected ? .bold : .regular)
                            .foregroundColor(.primary)

                        if unlocked {
                            // 已解锁：选中标记 / 占位保持高度一致
                            Text(isSelected ? "使用中" : " ")
                                .font(.caption2)
                                .foregroundColor(.indigo)
                        } else {
                            // 未解锁：条件 + 进度条
                            VStack(spacing: 2) {
                                Text(ch.unlockText)
                                    .font(.system(size: 9))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                ProgressView(value: ch.progress(
                                    level: dataManager.petLevel,
                                    focusMinutes: focusMinutes,
                                    streak: streak
                                ))
                                .tint(.indigo)
                                .scaleEffect(x: 1, y: 0.7)
                            }
                        }
                    }
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(isSelected ? Color.indigo.opacity(0.10) : Color.primary.opacity(0.04))
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// 从 Bundle 的 AppPetAssets/{charId}/ 读取一张静帧做商店预览
    static func shopPreviewImage(_ charId: String) -> UIImage? {
        guard let url = Bundle.main.url(
            forResource: "pet_idle_0",
            withExtension: "png",
            subdirectory: "AppPetAssets/\(charId)"
        ) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }

    // MARK: - 数据备份
    /// 生成备份 JSON 写入临时文件并弹出分享
    private func exportBackup() {
        do {
            let data = try BackupManager.makeBackupData()
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(BackupManager.suggestedFileName)
            try data.write(to: url, options: .atomic)
            shareURL = url
        } catch {
            restoreResultAlert = "导出失败：\(error.localizedDescription)"
        }
    }

    /// 处理导入的备份文件
    private func handleImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        let secured = url.startAccessingSecurityScopedResource()
        defer { if secured { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            try BackupManager.restore(from: data)
            restoreResultAlert = "恢复成功！课表、宠物和专注记录已还原 ✅"
        } catch {
            restoreResultAlert = "恢复失败：\(error.localizedDescription)"
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

    /// DDL 轰炸开关：独立 UserDefaults 存储；切换后申请授权并重建通知
    private var ddlBombBinding: Binding<Bool> {
        Binding(
            get: { NotificationManager.ddlBombEnabled },
            set: { enabled in
                NotificationManager.ddlBombEnabled = enabled
                rebuildNotificationsRequestingAuthIfNeeded(enabled)
            }
        )
    }

    /// 天气早安播报开关：独立 UserDefaults 存储；切换后申请授权并重建通知
    private var weatherBinding: Binding<Bool> {
        Binding(
            get: { NotificationManager.weatherEnabled },
            set: { enabled in
                NotificationManager.weatherEnabled = enabled
                rebuildNotificationsRequestingAuthIfNeeded(enabled)
            }
        )
    }

    /// 重建全部通知；开启时先确保已申请通知授权
    private func rebuildNotificationsRequestingAuthIfNeeded(_ enabling: Bool) {
        if enabling {
            NotificationManager.requestAuthorization { _ in
                NotificationManager.refreshAll()
            }
        } else {
            NotificationManager.refreshAll()
        }
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

// MARK: - 系统分享面板（备份文件导出用）
struct ActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
