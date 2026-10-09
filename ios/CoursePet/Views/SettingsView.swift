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
    // 导出结果行内提示（不用系统 alert：iOS 26 上 alert 呈现路径有崩溃嫌疑，一并排除）
    @State private var exportTipText: String?
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
    @State private var glassStyle: GlassStyle = .thin

    /// 提醒点行（拆出减小主 body 类型检查压力）
    /// ScrollView 没有系统 onDelete 滑删，改为行内 minus 按钮删除
    private func placeRow(_ place: MonitoredPlace) -> some View {
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
            Button {
                if let idx = locationReminder.places.firstIndex(where: { $0.id == place.id }) {
                    locationReminder.remove(at: IndexSet(integer: idx))
                }
            } label: {
                Image(systemName: "minus.circle.fill")
                    .foregroundColor(.red)
            }
            .buttonStyle(.plain)
        }
    }

    /// 分组头：白字+投影保证照片背景上可读，18pt 顶距拉开分组（ScrollView 需自带横向 16pt，List 时代由系统 inset 提供）
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.white.opacity(0.92))
            .shadow(color: .black.opacity(0.35), radius: 3, x: 0, y: 1)
            .padding(.top, 18)
            .padding(.horizontal, 16)
    }

    var body: some View {
        // NavigationStack：AI 管家/服务器模式入口是 NavigationLink（二级页），必须有栈容器
        NavigationStack {
        ZStack {
            GlassBackdrop()

            // 弃用 List：iOS 26 SDK 编译的 List 在 iOS 17.7 上会吞行底 padding（四轮加间距全无效）。
            // 改 ScrollView+VStack：卡片间距是纯布局算术，没有系统行为参与。
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                // ── 顶部大标题 ──
                    VStack(alignment: .leading, spacing: 2) {
                        Text("设置")
                            .font(.title)
                            .fontWeight(.bold)
                        Text("个性化你的课表与宠物")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.92))
                            .shadow(color: .black.opacity(0.35), radius: 3, x: 0, y: 1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
                    .padding(.horizontal, 16)

                // ── 核心（形象 / 动画速度 / 宠物名 / 学期日期 集中一组）──
                sectionHeader("核心")
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
                        NavigationLink {
                            SemesterDatePickerView(onSaved: { dataManager.savePublishedState() })
                        } label: {
                            HStack {
                                Text("学期开始日期")
                                Spacer()
                                if dataManager.semesterStartDate.isEmpty {
                                    Text("未设置")
                                        .foregroundColor(.secondary)
                                } else {
                                    Text(dataManager.semesterStartDate)
                                        .foregroundColor(.secondary)
                                }
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .glassRowCard()

                // ── 自动化（通知播报 / 位置提醒 / Siri）──
                sectionHeader("自动化")
                    Group {
                        // 通知与播报（默认折叠，点开才显示五个开关）
                        DisclosureGroup(isExpanded: $reminderOpen) {
                            Group {
                                Toggle("上课提醒（提前 15 分钟）", isOn: reminderBinding)
                                Toggle("DDL 轰炸（截止三连催）", isOn: ddlBombBinding)
                                Toggle("事件提醒（新作业等变化宠物主动说）", isOn: eventNudgeBinding)
                                Toggle("天气早安播报（每天 07:00）", isOn: weatherBinding)
                                Toggle("AI 晨报（生成后顶替天气播报）", isOn: aiBriefBinding)
                                Toggle("每周学习周报（周日 20:00）", isOn: weeklyBriefBinding)
                                Text("事件提醒：学习通/智慧树同步进来新作业时宠物会主动说一声（同类 30 分钟冷却，每天最多 6 条，宁少勿扰）")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .glassRowCard()
                        } label: {
                            HStack(spacing: 10) {
                                SettingIcon(color: .blue, systemImage: "bell.badge.fill")
                                Text("通知与播报选项")
                            }
                        }
                        Toggle("走近教学楼报下节课", isOn: locationReminderBinding)
                        if locationReminder.enabled && locationReminder.places.isEmpty {
                            Text("还没有提醒点：点下方按钮，站在教学楼/宿舍门口把当前位置存下来")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        ForEach(locationReminder.places) { place in
                            placeRow(place)
                        }
                        Button {
                            newPlaceName = ""
                            showAddPlaceAlert = true
                        } label: {
                            HStack(spacing: 10) {
                                SettingIcon(color: .orange, systemImage: "location.viewfinder")
                                Text("把当前位置添加为提醒点")
                                    .foregroundColor(.primary)
                            }
                        }
                        if let addError {
                            Text(addError)
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                        // 短信助手（Muse 式短信管家）：快递/验证码/银行/学校通知自动处理
                        NavigationLink {
                            SMSSettingsView()
                        } label: {
                            HStack(spacing: 10) {
                                SettingIcon(color: .green, systemImage: "message.badge.fill")
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("短信助手")
                                    Text("快递/验证码/银行/学校通知自动处理")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                    .glassRowCard()
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
                    // Siri 快捷指令放段尾（高级功能不抢主信息）
                    Group {
                        ShortcutsLink()
                        Text("支持对 Siri 说「今天有什么课」「记待办」「记一笔花销」，也可在快捷指令 App 里组合自动化")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .glassRowCard()
                    Text("位置提醒需允许「始终」定位；手动杀掉 App 后围栏失效，重新打开会自动恢复。每个地点每天最多提醒一次。")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.75))
                        .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)
                        .padding(.horizontal, 16)
                        .padding(.top, 4)

                // ── 灵动岛诊断（默认折叠；无 Mac 环境的远程排障面板）──
                sectionHeader("诊断")
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
                        .glassRowCard()
                    } label: {
                        HStack(spacing: 10) {
                            SettingIcon(color: .gray, systemImage: "doc.text.magnifyingglass")
                            Text("状态与日志")
                        }
                    }
                    .glassRowCard()

                // ── AI 能力 ──
                sectionHeader("AI 能力")
                    NavigationLink {
                        AgentSettingsView()
                    } label: {
                        HStack(spacing: 10) {
                            SettingIcon(color: .purple, systemImage: "sparkles")
                            VStack(alignment: .leading, spacing: 2) {
                                Text("AI 管家")
                                Text(serverConfigured
                                     ? "服务器模式已启用 · 对话走自建服务器"
                                     : (agentConfigured ? "端侧模式已配置 · 数据不出设备" : "未配置，点此填写 API Key"))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .glassRowCard()
                    NavigationLink {
                        CourseLibraryView(presentedAsSheet: false)
                    } label: {
                        HStack(spacing: 10) {
                            SettingIcon(color: .green, systemImage: "books.vertical.fill")
                            VStack(alignment: .leading, spacing: 2) {
                                Text("课件知识库")
                                Text("课件文件入库，AI 答题可引用")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .glassRowCard()

                // ── 外观 ──
                sectionHeader("外观")
                    Group {
                        Toggle("深色模式", isOn: dmBinding(\.darkMode))
                        // 玻璃质感 DIY：四档切换，实时生效
                        Picker("玻璃质感", selection: $glassStyle) {
                            ForEach(GlassStyle.allCases) { s in
                                Label(s.displayName, systemImage: s.icon).tag(s)
                            }
                        }
                        .onChange(of: glassStyle) { s in
                            GlassTheme.style = s
                            GlassChrome.apply(s)
                        }
                        // 自定义背景：选中的照片会成为玻璃页面的底（玻璃卡片透出它）
                        GlassBackgroundPicker()
                        HStack(spacing: 0) {
                            ForEach(BackgroundTheme.all) { theme in
                                themeCard(theme)
                            }
                        }
                        Text("当前主题：\(dataManager.backgroundColorName)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .glassRowCard()

                // ── 数据 ──
                sectionHeader("数据")
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
                        // 导出走"文件 App"通道：备份写入 Documents/Exports/，
                        // 用户在 文件 App → 我的iPhone → CoursePet → Exports 直接取。
                        // 不用分享面板（UIActivityViewController/ShareLink 在 iOS 26 均有闪退）。
                        Button {
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            exportBackup()
                        } label: {
                            HStack {
                                Image(systemName: "square.and.arrow.up.fill")
                                Text("导出备份文件")
                            }
                        }
                        if let tip = exportTipText {
                            Text(tip)
                                .font(.caption)
                                .foregroundColor(.green)
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
                    .glassRowCard()
                    Text("重装或换机前先导出备份。")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.75))
                        .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)
                        .padding(.horizontal, 16)
                        .padding(.top, 4)

                // ── 危险操作（独立分组，与数据备份拉开距离）──
                sectionHeader("危险操作")
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
                        Divider().background(Color.white.opacity(0.12))
                        // 退出登录（已登录时）/ 去登录（跳过登录状态时，回登录页的入口）
                        let isSkipMode = UserDefaults.standard.bool(forKey: "auth.skipped") && !AuthStore.isLoggedIn
                        if AuthStore.isLoggedIn || isSkipMode {
                            Button(role: .destructive) {
                                Task { @MainActor in
                                    let server = AgentConfigStore.loadServerConfig()
                                    if server.isConfigured {
                                        await AuthStore.logout(baseURL: server.baseURL)
                                    }
                                    // 退出登录后强制 App 重建 ContentView（isLoggedIn 回到 false）
                                    NotificationCenter.default.post(name: .coursepetForceLogout, object: nil)
                                }
                            } label: {
                                HStack {
                                    Image(systemName: isSkipMode ? "person.crop.circle.badge.plus" : "rectangle.portrait.and.arrow.right")
                                    Text(isSkipMode ? "去登录" : "退出登录")
                                        .foregroundColor(.red)
                                }
                            }
                        }
                    }
                    .glassRowCard()
                } // VStack（设置内容）
            }
            .scrollDismissesKeyboard(.interactively)
            .onAppear {
                diagnosticText = LADebug.text()
                glassStyle = GlassTheme.style
            }
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
    // iOS 26 上 UIActivityViewController（sheet 桥接/手动 present）与 List 行内 ShareLink 均有闪退，
    // 导出彻底改走"文件 App"通道：写入 Documents/Exports，用户自行从文件 App 取件转发。
    /// 生成备份 JSON 写入 Documents/Exports/（Info.plist 已开 UIFileSharingEnabled）
    /// 结果用行内文字反馈，不走系统 alert（排除 iOS 26 alert 呈现崩溃嫌疑）
    private func exportBackup() {
        do {
            _ = try BackupManager.exportToDocuments()
            exportTipText = "已导出到「文件」App → 我的 iPhone → CoursePet → Exports"
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

    // semesterBinding 已移除：改为 SemesterDatePickerView 二级页


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

    /// 事件提醒开关：绑 PetEventNudger（新作业等数据变化时宠物主动开口）
    private var eventNudgeBinding: Binding<Bool> {
        Binding(
            get: { PetEventNudger.isEnabled },
            set: { enabled in
                PetEventNudger.isEnabled = enabled
                if enabled { NotificationManager.requestAuthorization() }
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
    // 作业平台绑定已迁至事务页作业列表（PlatformSyncSection）；这里只留 Bark 推送
    @State private var serverEnabled = false
    // Bark 推送（服务器主动推送通道：任务结果 / 作业 DDL 提醒 / 平台告警）
    @State private var barkKey = ""
    @State private var barkTip: String?
    @State private var barkBusy = false
    // 通话音色（CosyVoice 大模型音色，复用百炼 Key；"" = 系统音色）
    @State private var callVoice = AgentCosyVoiceConfig.defaultVoice
    // SOUL 恢复默认人设的二次确认
    @State private var showSoulResetConfirm = false

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

            // ── Bark 推送（App 关着也能收到服务器的消息；清空服务器地址后隐藏）──
            if serverEnabled {
                Section(header: Text("推送通知 · Bark"), footer: Text("App 没开着也能收到：定时任务跑完的结果、作业截止提醒（截止前 24 小时 / 6 小时 / 1 小时各推一次）、平台登录失效告警。到 App Store 装免费的「Bark」，打开后把首页那串 Key 复制过来粘贴，保存时会发一条测试推送验证。留空保存 = 关闭推送。")) {
                    TextField("Bark Key（在 Bark App 里复制）", text: $barkKey)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Button {
                        saveBarkKey()
                    } label: {
                        Label("保存并测试推送", systemImage: "bell.badge.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(barkBusy)
                    if let tip = barkTip {
                        Text(tip)
                            .font(.caption)
                            .foregroundColor(tip.hasPrefix("保存失败") ? .red : .secondary)
                    }
                }
            }

            // ── 语音对话（功能 B：朗读 AI 回复）──
            Section(header: Text("语音"), footer: Text("开启后每条 AI 回复自动朗读；也可以点聊天气泡旁的小喇叭手动朗读。上课/图书馆场景建议关闭。「通话音色」决定语音通话里宠物的嗓音：选 CosyVoice 音色会直连阿里百炼实时合成（需在上方填「图像生成 Key · 阿里百炼」，按字符计费约 0.4 元/万字符，半小时通话约几分钱），没填 Key 或合成失败会自动改用系统音色。")) {
                Toggle("自动朗读 AI 回复", isOn: Binding(
                    get: { AgentSpeech.shared.isAutoSpeak },
                    set: { AgentSpeech.shared.isAutoSpeak = $0 }
                ))
                Picker("通话音色", selection: $callVoice) {
                    Text("系统音色（不消耗额度）").tag("")
                    ForEach(AgentCosyVoiceConfig.voices) { v in
                        Text(v.label).tag(v.id)
                    }
                }
                .onChange(of: callVoice) { newValue in AgentCosyVoice.voice = newValue }
                if !callVoice.isEmpty && !AgentCosyVoice.isConfigured {
                    Label("已选 CosyVoice 音色，但还没填百炼 Key：到上方端侧模式填「图像生成 Key」后生效", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }

            // ── 灵魂设定（Muse 式 SOUL.md 人格说明书）──
            Section(header: Text("灵魂设定"), footer: Text("SOUL.md 是宠物的人格说明书（八段式：我是谁/在乎什么/怎么说话/擅长什么/偏好等）。保存后下一轮对话生效：端侧直接注入，服务器模式自动推送到服务器，双端性格一致。")) {
                NavigationLink("编辑 SOUL.md 人格说明书") {
                    SoulEditorView()
                }
                Button {
                    showSoulResetConfirm = true
                } label: {
                    Label("恢复默认人设", systemImage: "arrow.counterclockwise")
                }
                .confirmationDialog("恢复默认会覆盖你手写的人格内容", isPresented: $showSoulResetConfirm, titleVisibility: .visible) {
                    Button("恢复默认", role: .destructive) {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        AgentSoul.removeCustomFile()
                        let md = AgentSoul.defaultSoul(petName: DataManager.shared.petName)
                        AgentSoul.save(md)
                        // 服务器模式：把默认人设也推过去，双端一致（失败静默，下次保存再推）
                        let server = AgentConfigStore.loadServerConfig()
                        if server.isConfigured {
                            Task {
                                await AgentRemoteClient.pushSoul(baseURL: server.baseURL,
                                                                 username: server.username,
                                                                 password: server.password,
                                                                 content: md)
                            }
                        }
                    }
                    Button("取消", role: .cancel) { }
                }
            }

            // ── 数据与隐私（从设置主页挪来的完整说明）──
            Section(footer: Text("端侧模式：API Key 只存本机 Keychain，数据不出设备；服务器模式：对话转由自建后端执行，数据进 PostgreSQL。配置主体存 Keychain，删除 App 重装后仍保留。")) {
                Text("配置与隐私说明")
                    .foregroundColor(.secondary)
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
            callVoice = AgentCosyVoice.voice
            let server = AgentConfigStore.loadServerConfig()
            serverURL = server.baseURL
            serverUser = server.username
            serverPass = server.password
            // 作业平台绑定状态由事务页 PlatformSyncSection 自行拉取；这里只管 Bark 回显
            serverEnabled = server.isConfigured
            if server.isConfigured {
                // Bark：回读已保存的 Key（重新进来能看到，避免误覆盖）
                Task { @MainActor in
                    if let key = await AgentRemoteClient.fetchPushKey(
                        baseURL: server.baseURL, username: server.username, password: server.password) {
                        barkKey = key
                    }
                }
            }
        }
    }

    // MARK: Bark 推送（保存 Key + 服务器发测试推送验证通路）
    private func saveBarkKey() {
        let server = AgentConfigStore.loadServerConfig()
        guard server.isConfigured else { return }
        barkBusy = true
        barkTip = "正在保存并测试…"
        Task { @MainActor in
            defer { barkBusy = false }
            let key = barkKey.trimmingCharacters(in: .whitespaces)
            let result = await AgentRemoteClient.savePushKey(
                baseURL: server.baseURL, username: server.username,
                password: server.password, barkKey: key)
            if !result.saved {
                barkTip = "保存失败：\(result.reason ?? "服务器暂时连不上")"
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                return
            }
            if key.isEmpty {
                barkTip = "已关闭推送"
            } else if result.testOk {
                barkTip = "已保存，测试推送已发出，打开 Bark App 看看"
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } else {
                barkTip = "已保存，但测试推送没送达：检查 Key 是否复制完整"
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
            }
        }
    }
}

// MARK: - 智慧树扫码绑定弹层（手机直连智慧树出码 → 智慧树 App 扫 → 手机接管会话）
// 流程：qrCreate 出码 → 每 2 秒 qrPoll → 确认后 qrLogin 落会话 cookie（只存手机）→ 绑定完成。
// 智慧树 WAF 拦服务器机房出口，二维码与后续拉取都由手机直连，不经过服务器。
// expired/canceled/failed 点「重新获取」自增 attempt，task(id:) 自动重开一轮。
struct ZhihuishuQRSheet: View {
    var onBound: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var attempt = 1
    @State private var qrImage: UIImage?
    @State private var phase: Phase = .loading
    @State private var tip = ""

    enum Phase { case loading, waiting, scanned, expired, canceled, failed }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                ZStack {
                    // 玻璃外板 + 白底内托盘：二维码图片本身是白底 PNG，深色模式下也能扫
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .fill(Color(.systemBackground).opacity(0.18)))
                        .overlay(
                            LinearGradient(colors: [.white.opacity(0.30), .white.opacity(0.06),
                                                    .clear, .white.opacity(0.10)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing)
                                .blendMode(.plusLighter))
                        .overlay(
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .strokeBorder(
                                    LinearGradient(colors: [.white.opacity(0.80), .white.opacity(0.14),
                                                            .white.opacity(0.32)],
                                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                                    lineWidth: 1)
                        )
                        .shadow(color: .black.opacity(0.14), radius: 16, x: 4, y: 8)
                        .shadow(color: .black.opacity(0.05), radius: 6, x: -2, y: -3)
                        .frame(width: 248, height: 248)
                    if let qrImage {
                        Image(uiImage: qrImage)
                            .resizable()
                            .interpolation(.none)
                            .scaledToFit()
                            .padding(14)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Color(.systemBackground)))
                            .frame(width: 216, height: 216)
                    } else {
                        ProgressView()
                    }
                }
                .opacity(phase == .scanned ? 0.4 : 1)

                Text(statusText)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)

                if phase == .expired || phase == .canceled || phase == .failed {
                    Button {
                        attempt += 1
                    } label: {
                        Label("重新获取二维码", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(GlassButtonStyle(tint: .accentColor))
                }
                Spacer()
            }
            .padding(24)
            .navigationTitle("扫码绑定智慧树")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .task(id: attempt) { await runFlow() }
    }

    private var statusText: String {
        switch phase {
        case .loading: return "正在向智慧树申请二维码…"
        case .waiting: return tip
        case .scanned: return "已扫码，请在智慧树 App 里确认登录"
        case .expired: return "二维码已过期"
        case .canceled: return "已在手机上取消登录"
        case .failed: return tip.isEmpty ? "绑定失败" : tip
        }
    }

    private func runFlow() async {
        do {
            phase = .loading
            qrImage = nil
            let start = try await AgentZhsClient.qrCreate()
            qrImage = UIImage(data: Data(base64Encoded: start.imgBase64,
                                         options: [.ignoreUnknownCharacters]) ?? Data())
            phase = .waiting
            tip = "打开智慧树 App → 扫一扫，对准这个码"
            // 轮询到 TTL 截止（智慧树二维码约 5 分钟有效）；确认后登录跳板在手机本地完成
            let deadline = Date().addingTimeInterval(300)
            while Date() < deadline {
                try await Task.sleep(nanoseconds: 2_000_000_000)
                let st = try await AgentZhsClient.qrPoll(token: start.token)
                switch st.status {
                case 0:
                    phase = .scanned
                case 1:
                    guard let once = st.oncePassword, !once.isEmpty else {
                        phase = .failed
                        tip = "确认响应缺少登录凭据，请重试"
                        return
                    }
                    _ = try await AgentZhsClient.qrLogin(oncePassword: once)
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    onBound()
                    dismiss()
                    return
                case 2:
                    phase = .expired
                    return
                case 3:
                    phase = .canceled
                    return
                default:
                    break // -1 未扫：继续轮询
                }
            }
            phase = .expired
        } catch is CancellationError {
            // 弹层被关闭，轮询任务随 task(id:) 取消，无需处理
        } catch {
            phase = .failed
            tip = error.localizedDescription
        }
    }
}

// MARK: - 学期开始日期二级页（更柔和的选择体验）
struct SemesterDatePickerView: View {
    @EnvironmentObject private var dataManager: DataManager
    let onSaved: () -> Void

    // 本地 @State 临时存选中的日期，用户点"保存"才写入 DataManager + UserDefaults
    @State private var tempDate: Date = Date()

    var body: some View {
        Form {
            Section {
                DatePicker(
                    "选择开学日期",
                    selection: $tempDate,
                    displayedComponents: .date
                )
                .datePickerStyle(.graphical)
            } header: {
                Text("选你的学期开始那一天")
            } footer: {
                Text("设置后，课表周数、灵动岛、下节课提醒都会基于这个日期计算")
            }

            Section {
                Button {
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    let dateStr = WeekMath.formatDate(tempDate)
                    // 写入 DataManager（内存 + UserDefaults + JSON 双链路都覆盖）
                    dataManager.semesterStartDate = dateStr
                    // savePublishedState 走完整链路：JSON 双写 + UserDefaults 双写
                    dataManager.savePublishedState()
                    // 同时直接写 standard UserDefaults，双保险（课表显示直接读这个）
                    UserDefaults.standard.set(dateStr, forKey: "semester.startDate")
                    onSaved()
                } label: {
                    HStack {
                        Spacer()
                        Text("保存")
                            .fontWeight(.semibold)
                        Spacer()
                    }
                }
                .buttonStyle(.borderedProminent)
            }

            // 实时预览：选完立刻看到算出的周数（让用户确认选对了）
            Section("实时预览") {
                let dateStr = WeekMath.formatDate(tempDate)
                let week = WeekMath.currentWeekNumber(startDateStr: dateStr, now: Date()) ?? 1
                LabeledContent("开学日期", value: dateStr)
                LabeledContent("今天是第", value: "\(week) 周")
                let debug = WeekMath.weekDebugText(startDateStr: dateStr)
                Text(debug)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle("学期开始日期")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            // 进入二级页时，用已保存的日期初始化 DatePicker
            if let existing = WeekMath.parseDate(dataManager.semesterStartDate) {
                tempDate = existing
            }
        }
    }
}

// SemesterDebugRow 已删除（课表永远第 1 周根因 WeekMath 单位换算 bug 已修复 2026-10-02）

