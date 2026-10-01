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
    @State private var showImporter = false
    @State private var restoreResultAlert: String?
    // 预生成的备份文件（进设置页即生成，供 ShareLink 分享）
    @State private var backupURL: URL?
    // 灵动岛诊断面板文本（进入设置页或点按钮时刷新）
    @State private var diagnosticText = "（打开设置页时刷新）"
    // AI 管家配置状态（明细编辑在二级页；主页只显示入口行 + 状态副标题）
    @State private var agentConfigured = false
    @State private var serverConfigured = false
    // 位置提醒（走近教学楼报下节课）：围栏列表与开关状态都在 LocationReminderManager
    @ObservedObject private var locationReminder = LocationReminderManager.shared
    @State private var showAddPlaceAlert = false
    @State private var newPlaceName = ""
    @State private var addError: String?
    // 设置页精简：形象管理收进弹层（PetAvatarSheet），长内容默认折叠
    @State private var showPetSheet = false
    @State private var reminderOpen = false
    @State private var diagnosticOpen = false

    var body: some View {
        // NavigationStack：AI 管家/服务器模式入口是 NavigationLink（二级页），必须有栈容器
        NavigationStack {
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

                // ── 核心（形象 / 动画速度 / 宠物名 / 学期日期 集中一组）──
                Section(header: Text("核心")) {
                    Group {
                        TextField("宠物名字", text: nameBinding)
                        Button {
                            showPetSheet = true
                        } label: {
                            HStack(spacing: 12) {
                                // 当前形象小预览（静帧）
                                Group {
                                    if let img = Self.shopPreviewImage(dataManager.charId) {
                                        Image(uiImage: img).resizable().scaledToFit()
                                    } else {
                                        Text("🐾")
                                    }
                                }
                                .frame(width: 44, height: 44)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(dataManager.petName)
                                        .foregroundColor(.primary)
                                    Text("虚拟形象 · 改名 · 活动 · 连接")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        // 动画速度保留在主页（单行，无占位压力）
                        Picker("动画速度", selection: dmBinding(\.animSpeed)) {
                            Text("慢").tag(AppSettings.AnimSpeed.slow)
                            Text("中").tag(AppSettings.AnimSpeed.mid)
                            Text("快").tag(AppSettings.AnimSpeed.fast)
                        }
                        DatePicker(
                            "学期开始日期",
                            selection: semesterBinding,
                            displayedComponents: .date
                        )
                        // 落盘诊断：显示当前内存里已保存的原始值。
                        // 若这里显示"（空）"或与上方选择不符，说明写入链路有问题（截图反馈）；
                        // 若这里正确但课表仍是第 1 周，问题在周数换算侧。
                        Text("已保存：\(dataManager.semesterStartDate.isEmpty ? "（空）" : dataManager.semesterStartDate)（\(dataManager.semesterStartDate.count) 字符）· 实算第 \(WeekMath.currentWeekNumber(startDateStr: dataManager.semesterStartDate).map(String.init) ?? "计算失败") 周 · \(StorageLocation.usesAppGroup ? "AppGroup" : "本地")存储")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .glassListRow()
                }

                // ── 自动化（Siri / 位置提醒 / 通知播报）──
                Section(header: Text("自动化"), footer: Text("需允许「始终」定位；手动杀掉 App 后围栏失效，重新打开会自动恢复。每个地点每天最多提醒一次。")) {
                    ShortcutsLink()
                    Text("支持对 Siri 说「今天有什么课」「记待办」「记一笔花销」，也可在快捷指令 App 里组合自动化")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Group {
                        Toggle("走近教学楼报下节课", isOn: locationReminderBinding)
                        if locationReminder.enabled && locationReminder.places.isEmpty {
                            Text("还没有提醒点：点下方按钮，站在教学楼/宿舍门口把当前位置存下来")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        ForEach(locationReminder.places) { place in
                            HStack(spacing: 8) {
                                Image(systemName: "mappin.circle.fill")
                                    .foregroundColor(.orange)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(place.name)
                                    Text(String(format: "半径 %.0f 米", place.radius))
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                            }
                        }
                        .onDelete { offsets in
                            locationReminder.remove(at: offsets)
                        }
                        Button {
                            newPlaceName = ""
                            showAddPlaceAlert = true
                        } label: {
                            Label("把当前位置添加为提醒点", systemImage: "plus.circle.fill")
                        }
                        if let addError {
                            Text(addError)
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                    }
                    .glassListRow()
                    .alert("添加提醒点", isPresented: $showAddPlaceAlert) {
                        TextField("地点名称（如：教学楼A）", text: $newPlaceName)
                        Button("添加") {
                            let name = newPlaceName
                            Task { @MainActor in
                                addError = await locationReminder.addCurrentLocation(named: name)
                            }
                        }
                        Button("取消", role: .cancel) { }
                    } message: {
                        Text("将把你的当前位置存为提醒点，走进该范围时提醒下一节课。")
                    }
                    // 通知与播报（默认折叠，点开才显示五个开关）
                    DisclosureGroup(isExpanded: $reminderOpen) {
                        Group {
                            Toggle("上课提醒（提前 15 分钟）", isOn: reminderBinding)
                            Toggle("DDL 轰炸（截止三连催）", isOn: ddlBombBinding)
                            Toggle("天气早安播报（每天 07:00）", isOn: weatherBinding)
                            Toggle("AI 晨报（生成后顶替天气播报）", isOn: aiBriefBinding)
                            Toggle("每周学习周报（周日 20:00）", isOn: weeklyBriefBinding)
                            Text("DDL 轰炸：截止前一天 20:00 / 当天 08:00 / 当天 18:00 各提醒一次")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .glassListRow()
                    } label: {
                        Text("通知与播报选项")
                    }
                    .glassListRow()
                }

                // ── 灵动岛诊断（默认折叠；无 Mac 环境的远程排障面板）──
                Section(header: Text("诊断")) {
                    DisclosureGroup(isExpanded: $diagnosticOpen) {
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
                    } label: {
                        Text("状态与日志")
                    }
                    .glassListRow()
                }

                // ── AI 能力 ──
                Section(header: Text("AI 能力")) {
                    NavigationLink {
                        AgentSettingsView()
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("AI 管家")
                            Text(serverConfigured
                                 ? "服务器模式已启用 · 对话走自建服务器"
                                 : (agentConfigured ? "端侧模式已配置 · 数据不出设备" : "未配置，点此填写 API Key"))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .glassListRow()
                    NavigationLink {
                        CourseLibraryView(presentedAsSheet: false)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("课件知识库")
                            Text("课件文件入库，AI 答题可引用")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .glassListRow()
                }

                // ── 外观 ──
                Section(header: Text("外观")) {
                    Group {
                        Toggle("深色模式", isOn: dmBinding(\.darkMode))
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

                // ── 数据 ──
                Section(header: Text("数据"), footer: Text("重装或换机前先导出备份。")) {
                    Group {
                        // 存储模式诊断：App Group 权限无效时数据走本地沙盒（仍持久，仅小组件不共享）
                        HStack(spacing: 8) {
                            Image(systemName: StorageLocation.usesAppGroup ? "sharedwithyou" : "internaldrive.fill")
                                .foregroundColor(StorageLocation.usesAppGroup ? .green : .orange)
                            Text(StorageLocation.usesAppGroup
                                 ? "存储正常（与小组件共享）"
                                 : "本地存储（不共享给小组件）")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        // 导出用 SwiftUI 原生 ShareLink：彻底绕开 UIActivityViewController
                        //（iOS 26 上无论 sheet 桥接还是手动 present 都会闪退回桌面）。
                        // 进设置页即预生成备份文件，ShareLink 点击即分享。
                        if let backupURL {
                            ShareLink(item: backupURL, preview: SharePreview("CoursePet 数据备份")) {
                                HStack {
                                    Image(systemName: "square.and.arrow.up.fill")
                                    Text("导出备份文件")
                                }
                            }
                        } else {
                            Button {
                                backupURL = try? BackupManager.exportToTemporaryFile()
                                if backupURL == nil { restoreResultAlert = "备份生成失败，请重试" }
                            } label: {
                                HStack {
                                    Image(systemName: "square.and.arrow.up.fill")
                                    Text("导出备份文件")
                                }
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

                // ── 危险操作（独立分组，与数据备份拉开距离）──
                Section(header: Text("危险操作")) {
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
                .task {
                    // 进设置页预生成备份文件（几十 KB 级，开销可忽略），ShareLink 直接可用
                    backupURL = try? BackupManager.exportToTemporaryFile()
                }
                .onAppear { diagnosticText = LADebug.text() }
        }
        .sheet(isPresented: $showPetSheet) {
            PetAvatarSheet()
        }
        .onAppear {
            // 兼容旧数据：charId 不在九种预设里时归一为 char1
            if PetCatalog.character(id: dataManager.charId) == nil {
                dataManager.charId = "char1"
            }
            dataManager.savePublishedState()
            // AI 管家：刷新主页入口行的状态副标题（明细在二级页读取）
            agentConfigured = AgentConfigStore.load().isConfigured
            serverConfigured = AgentConfigStore.loadServerConfig().isConfigured
        }
        .alert("确认清空", isPresented: $showResetConfirm) {
            Button("取消", role: .cancel) {}
            Button("清空", role: .destructive) { resetAll() }
        } message: {
            Text("确定要清空全部数据吗？课表、宠物进度和设置都将被清除，此操作不可撤销。")
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
        } // NavigationStack
    }

    /// 从 Bundle 的 AppPetAssets/{charId}/ 读取一张静帧做商店预览
    /// （形象网格管理已收进 PetAvatarSheet，这里只保留预览图读取供入口行使用）
    static func shopPreviewImage(_ charId: String) -> UIImage? {
        guard let url = Bundle.main.url(
            forResource: "pet_idle_0",
            withExtension: "png",
            subdirectory: "AppPetAssets/\(charId)"
        ) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }

    // MARK: - 数据备份
    // 导出已改为 SwiftUI 原生 ShareLink（见上方备份 Section），不再使用
    // UIActivityViewController——iOS 26 上呈现它必闪退（sheet 桥接与手动 present 均复现）。

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

    // （AI 管家端侧 + 服务器模式已统一在二级页 AgentSettingsView，见文件末尾）


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

    /// AI 晨报开关：独立 UserDefaults 存储；开启后申请授权并拉取/重排晨报
    private var aiBriefBinding: Binding<Bool> {
        Binding(
            get: { NotificationManager.aiBriefEnabled },
            set: { enabled in
                NotificationManager.aiBriefEnabled = enabled
                rebuildNotificationsRequestingAuthIfNeeded(enabled)
            }
        )
    }


    /// 每周学习周报开关：独立 UserDefaults 存储；开启后申请授权并立即重建（周日当天会拉取排程）
    private var weeklyBriefBinding: Binding<Bool> {
        Binding(
            get: { NotificationManager.weeklyBriefEnabled },
            set: { enabled in
                NotificationManager.weeklyBriefEnabled = enabled
                rebuildNotificationsRequestingAuthIfNeeded(enabled)
            }
        )
    }

    /// 位置提醒开关：走 LocationReminderManager（开启时重建围栏、关闭时全部停掉）
    private var locationReminderBinding: Binding<Bool> {
        Binding(
            get: { locationReminder.enabled },
            set: { enabled in
                locationReminder.setEnabled(enabled)
                if enabled { rebuildNotificationsRequestingAuthIfNeeded(true) }
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

// MARK: - AI 管家设置页（端侧 + 服务器双模式统一配置，一页填齐）
struct AgentSettingsView: View {
    // 端侧模式字段
    @State private var agentAPIKey = ""
    @State private var agentBaseURL = AgentConfig.default.baseURL
    @State private var agentModel = AgentConfig.default.model
    @State private var agentVisionModel = ""
    @State private var agentImageGenKey = ""
    @State private var keychainWarning: String?
    @State private var savedTip: String?
    // 服务器模式字段
    @State private var serverURL = ""
    @State private var serverUser = ""
    @State private var serverPass = ""
    @State private var serverTip: String?

    var body: some View {
        Form {
            Section(header: Text("端侧模式"), footer: Text("API Key 只存本机 Keychain，不上传任何服务器，兼容任何 OpenAI 格式接口。对话走「主模型」，拍照/带图消息自动切「图像理解模型」（需同一家服务商，共用地址与 Key），留空则全部走主模型。「图像生成 Key」用于宠物画图（阿里百炼 dashscope 开通，选填，独立计费约 0.2 元/张）。")) {
                // Key 输入：回显时只显示占位符，避免明文泄露在屏幕上
                SecureField("API Key（sk-…）", text: $agentAPIKey)
                TextField("接口地址", text: $agentBaseURL)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                TextField("主模型 · 对话（如 glm-4.7-flash）", text: $agentModel)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                TextField("图像理解模型 · 拍照识别（可选）", text: $agentVisionModel)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                SecureField("图像生成 Key · 阿里百炼（选填，宠物画图用）", text: $agentImageGenKey)
            }
            Section {
                Button {
                    AgentConfigStore.save(
                        baseURL: agentBaseURL,
                        model: agentModel,
                        // 占位符原样保存时视为"未修改"，避免把圆点串存成真 Key
                        apiKey: agentAPIKey.contains("••") ? AgentConfigStore.load().apiKey : agentAPIKey,
                        visionModel: agentVisionModel
                    )
                    // 图像生成 Key（阿里百炼，独立条目存储）：占位符原样保存时视为"未修改"
                    AgentImageGen.saveKey(agentImageGenKey.contains("••") ? AgentImageGen.loadKey() : agentImageGenKey)
                    keychainWarning = AgentConfigStore.keychainAvailable
                        ? nil
                        : "Keychain 不可用，已降级保存到本地偏好（删除重装后可能需要重填）"
                    if !agentAPIKey.contains("••") { agentAPIKey = "••••••••（已保存）" }
                    if !agentImageGenKey.contains("••") { agentImageGenKey = "••••••••（已保存）" }
                    savedTip = "已保存，对话将使用以上配置"
                } label: {
                    Label("保存端侧配置", systemImage: "checkmark.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                if let tip = savedTip {
                    Text(tip).font(.caption).foregroundColor(.secondary)
                }
                if let warning = keychainWarning {
                    Text(warning).font(.caption).foregroundColor(.orange)
                }
            }

            // ── 服务器模式（可选，三项填齐自动启用）──
            Section(header: Text("服务器模式（可选）"), footer: Text("三项填齐后，AI 管家的对话将转由你的服务器执行（ReAct 循环跑在服务端，数据进 PostgreSQL）；清空地址保存 = 回到端侧模式（数据不出设备）。首次对话会自动注册账号。")) {
                TextField("服务器地址（https://xxx.trycloudflare.com）", text: $serverURL)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                TextField("用户名", text: $serverUser)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                SecureField("密码", text: $serverPass)
            }
            Section {
                Button {
                    AgentConfigStore.saveServerConfig(url: serverURL, user: serverUser, pass: serverPass)
                    serverTip = serverURL.trimmingCharacters(in: .whitespaces).isEmpty
                        ? "已清空：回到端侧模式"
                        : "已保存：对话将走服务器模式"
                    // 保存即同步一次本地课表（fire-and-forget，静默失败；聊天前还有兜底同步）
                    let trimmed = serverURL.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty {
                        Task {
                            await AgentRemoteClient.syncCoursesIfNeeded(baseURL: trimmed,
                                                                        username: serverUser,
                                                                        password: serverPass)
                        }
                    }
                } label: {
                    Label("保存服务器配置", systemImage: "server.rack")
                        .frame(maxWidth: .infinity)
                }
                if let tip = serverTip {
                    Text(tip).font(.caption).foregroundColor(.secondary)
                }
            }

            // ── 语音对话（功能 B：朗读 AI 回复）──
            Section(header: Text("语音"), footer: Text("开启后每条 AI 回复自动朗读；也可以点聊天气泡旁的小喇叭手动朗读。上课/图书馆场景建议关闭。")) {
                Toggle("自动朗读 AI 回复", isOn: Binding(
                    get: { AgentSpeech.shared.isAutoSpeak },
                    set: { AgentSpeech.shared.isAutoSpeak = $0 }
                ))
            }

            // ── 灵魂设定（Muse 式 SOUL.md 人格说明书）──
            Section(header: Text("灵魂设定"), footer: Text("SOUL.md 是宠物的人格说明书（八段式：我是谁/在乎什么/怎么说话/擅长什么/偏好等）。保存后下一轮对话生效：端侧直接注入，服务器模式自动推送到服务器，双端性格一致。")) {
                NavigationLink("编辑 SOUL.md 人格说明书") {
                    SoulEditorView()
                }
            }

            // ── 数据与隐私（从设置主页挪来的完整说明）──
            Section {
                EmptyView()
            } header: {
                Text("数据与隐私")
            } footer: {
                Text("端侧模式：API Key 只存本机 Keychain，数据不出设备；服务器模式：对话转由自建后端执行，数据进 PostgreSQL。配置主体存 Keychain，删除 App 重装后仍保留。")
            }
        }
        .navigationTitle("AI 管家")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            let config = AgentConfigStore.load()
            agentBaseURL = config.baseURL
            agentModel = config.model
            agentVisionModel = config.visionModel
            if !config.apiKey.isEmpty { agentAPIKey = "••••••••（已保存）" }
            if !AgentImageGen.loadKey().isEmpty { agentImageGenKey = "••••••••（已保存）" }
            let server = AgentConfigStore.loadServerConfig()
            serverURL = server.baseURL
            serverUser = server.username
            serverPass = server.password
        }
    }
}
