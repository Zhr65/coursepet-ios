// MARK: - CoursePet 主 App（含 Live Activity 启动检查）
import SwiftUI
import ActivityKit
import UserNotifications

// 登出广播：设置页退出登录 → ContentView 强制重建回到登录页
extension Notification.Name {
    static let coursepetForceLogout = Notification.Name("coursepet.forceLogout")
    static let coursepetIntelligentModeChanged = Notification.Name("coursepet.intelligentModeChanged")
    // 登录页"未配置服务器 / 已配置服务器"点击 → ContentView 切到设置 tab
    static let coursepetOpenSettings = Notification.Name("coursepet.openSettings")
}

@main
struct CoursePetApp: App {
    @StateObject private var dataManager = DataManager.shared
    @Environment(\.scenePhase) private var scenePhase
    /// 本进程是否真正到过前台。兼作两用：
    /// ① 首次为 true 的那一刻才跑冷启动任务；② 区分两种 .background——
    /// 用户从界面退到后台（要打结算终点）vs 系统为执行灵动岛/锁屏按钮 Intent
    /// 在后台拉起进程（首帧即 .background、从未到过前台，绝不能打点，
    /// 否则会把 App 已死的那段时间也算进专注）
    @State private var didBecomeActive = false

    init() {
        // 启动时把 Bundle 内置的宠物 PNG 帧安装到 App Group 容器（已装过则跳过），
        // 这样主 App / Widget / 灵动岛都会优先显示真实形象图而不是程序化兜底宠物
        PetAssetInstaller.installIfNeeded()
        // 建好 Documents/Pet3D/ 目录，让 3D 宠物模型（.usdz）能从「文件」App 直接投放
        Pet3DModelLocator.prepareImportFolder()
        // ⚠️ 自动结算/清孤儿岛**不能放这里**：灵动岛/锁屏的暂停·继续·结束按钮是主 App
        // 里的 App Intent，系统为执行它会在**后台拉起 App 进程**（不打开界面）。此时
        // init() 若跑清理会把正在进行的专注岛 end 掉、把专注会话提前结算。
        // 故挪到「App 真正回到前台可见」的 .active 时序点（后台被 Intent 拉起不触发）。
        // 通知点击路由 + 前台横幅：center 对 delegate 是弱引用，必须保活（shared 单例持有）
        UNUserNotificationCenter.current().delegate = NotificationRouter.shared
        // 主 App 启动时注入数据保存钩子：每次保存/清空数据后重建本地课程提醒通知。
        // DataManager 在 Shared 中不能引用主 App 类型，故用静态钩子解耦；
        // Widget / Live Activity 扩展进程中该钩子保持 nil，不影响扩展。
        DataManager.onStateSaved = {
            NotificationManager.refreshAll()
            // 数据变化（加/删课程等）后立即检查：若新课程已在课前 15 分钟窗口内，马上上灵动岛
            LiveActivityManager.checkAndStartIfNeeded()
        }
        // 快递增删/取件后重建取件提醒通知（独立于 onStateSaved，扩展进程不注入）
        DataManager.onParcelsChanged = {
            NotificationManager.refreshAll()
        }
        // 作业增删/勾选后也重建通知：让 DDL 三级轰炸始终与最新作业数据一致
        DataManager.onHomeworksChanged = {
            NotificationManager.refreshAll()
        }
        // 课表导入/删改后即时同步到服务器（原则 7 数据同源）：
        // 服务器模式开启时，后端 Agent 查的课表永远与手机一致；指纹节流，无变化零开销
        DataManager.onCoursesChanged = {
            let server = AgentConfigStore.loadServerConfig()
            guard server.isConfigured else { return }
            Task {
                await AgentRemoteClient.syncCoursesIfNeeded(baseURL: server.baseURL,
                                                            username: server.username,
                                                            password: server.password)
            }
        }
        // 多课程表切换/新建/删除后重建本地通知（按当前活动课表的课程集合重新调度）
        DataManager.onTimetablesChanged = {
            NotificationManager.refreshAll()
            LiveActivityManager.checkAndStartIfNeeded()
        }
        // 账本增删后同步服务器（多端统一账本）：新增上传、删除远端删除，失败静默不挡本地
        DataManager.onLedgerChanged = { added, deletedId in
            let server = AgentConfigStore.loadServerConfig()
            guard server.isConfigured else { return }
            Task {
                if let added {
                    await AgentRemoteClient.pushLedgerEntry(baseURL: server.baseURL,
                                                            username: server.username,
                                                            password: server.password,
                                                            entry: added)
                } else if let deletedId {
                    await AgentRemoteClient.deleteLedgerEntryRemote(baseURL: server.baseURL,
                                                                    username: server.username,
                                                                    password: server.password,
                                                                    entryId: deletedId)
                }
            }
        }
        // 位置提醒：冷启动重建地理围栏（幂等，可重复调用）
        LocationReminderManager.shared.bootstrap()
        // 短信助手：开关开着就装私有 API 监听（轻量无副作用，后台被 Intent 拉起也无害；
        // 不碰专注岛/结算，不存在 cleanupOrphansOnLaunch 那种 init 禁区问题）
        SMSSyncManager.bootstrap()
        // 全局导航/标签栏液态玻璃化（见 GlassTheme.swift）
        GlassChrome.install()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(dataManager)
                // darkMode 是 DataManager 的 @Published 属性，切换设置后立即生效
                .preferredColorScheme(dataManager.darkMode ? .dark : .light)
        }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .active:
                // 首次真正回到前台才跑冷启动任务（挪出 init() 的原因见 init() 说明：
                // 后台被岛按钮 Intent 拉起时 init() 会误清专注岛/误结算正在进行的专注）
                let firstActivation = !didBecomeActive
                didBecomeActive = true
                if firstActivation {
                    // 杀掉 App / 岛按钮结束时没走正常结束流程的专注：补最后一段 + 补奖励
                    FocusAutoSettle.settleOnLaunch()
                    // 杀后台后系统里的专注岛 Activity 不会自动移除（会继续计时），
                    // 而专注状态只存内存、重开必然丢失 —— 清掉这种孤儿活动
                    FocusActivityManager.cleanupOrphansOnLaunch()
                }
                // App 回到前台时检查是否需要启动 Live Activity
                LiveActivityManager.checkAndStartIfNeeded()
                // App 回到前台：按最新课表重建未来 7 天的课程提醒通知
                NotificationManager.refreshAll()
                // 定时任务结果拉取（Muse 式异步任务；60s 内部节流，严禁挂 refreshAll 链）
                NotificationManager.refreshAgentTasks()
                // 作业平台同步拉取（服务器 30 分钟轮询学习通；端侧 3 分钟节流，静默失败）
                Task { await AgentRemoteClient.syncAssignmentsIfNeeded() }
                // 位置提醒：回前台重建围栏（手动杀掉 App 导致围栏失效后自愈）
                LocationReminderManager.shared.bootstrap()
                // 彩蛋成就：早上 8 点前打开 App 解锁「早起鸟」（静默解锁，成就墙可见）
                if Calendar.current.component(.hour, from: Date()) < 8 {
                    AchievementManager.unlockIfNeeded("early_bird")
                }
            case .inactive:
                // 控制中心 / 下拉通知触发 inactive：只检查课程岛，别动专注岛
                //（用户可能只是拉一下控制中心，不想专注计时停）
                LiveActivityManager.checkAndStartIfNeeded()
            case .background:
                // 只打退后台时刻（冷启动结算的终点），不 end 岛。
                // iOS 不给区分"按 Home 退后台"和"杀 App"的 API——两个都是 .background。
                // 退后台不动岛，杀 App 时冷启动 FocusAutoSettle 自动结算。
                // 条件 didBecomeActive：排除"系统为跑岛按钮 Intent 在后台拉起进程"
                // 这种情况（首帧就是 .background，从未到过前台，不能打点）
                if didBecomeActive, FocusActiveSegment.get() != nil {
                    FocusActiveSegment.markBackground()
                }
            @unknown default:
                break
            }
        }
    }
}

// MARK: - 主界面 TabView
struct ContentView: View {
    @EnvironmentObject var dataManager: DataManager
    @State private var selectedTab = 0
    /// 登录态（读 AuthKeychain 的 refresh_token；有就认为已登录，access_token 过期由网络层自动续）
    @State private var isLoggedIn = AuthStore.isLoggedIn
    /// 用户在登录页点过"先跳过"：不再拦登录墙，直到真正登录或登出
    @AppStorage("auth.skipped") private var skippedLogin = false
    /// 正在尝试自动续 Token（防止闪一下登录页再闪回主页）
    @State private var autoRefreshing = true
    /// 智能模式总开关（极简模式=关=移除聊聊 tab + 停 AI 功能）
    /// 注意：必须读 App Group suite（StorageLocation.defaults），因为设置页写入 App Group。
    /// 用 @Published 状态 + onChange 监听实现 App Group UserDefaults 观察。
    @State private var intelligentMode: Bool = StorageLocation.defaults.object(forKey: "intelligent.mode") as? Bool ?? true
    /// 扫一扫全屏页（coursepet://scan 深链触发：事务页按钮/锁屏小组件/Siri 快捷指令都汇到这里）
    @State private var showScanner = false

    var body: some View {
        Group {
            if autoRefreshing {
                ProgressView("登录中…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !isLoggedIn && !skippedLogin {
                LoginView(onLoggedIn: {
                    isLoggedIn = true
                }, onSkipped: {
                    withAnimation { skippedLogin = true }
                })
            } else {
                mainTabs
            }
        }
        // 监听设置页智能模式开关变化（设置页 Toggle 发通知，因为它写 App Group suite，
        // @AppStorage 读不到；这里用 @State + 通知刷新）
        .onReceive(NotificationCenter.default.publisher(for: .coursepetIntelligentModeChanged)) { _ in
            intelligentMode = StorageLocation.defaults.object(forKey: "intelligent.mode") as? Bool ?? true
        }
        .task { await tryAutoRefresh() }
        .onReceive(NotificationCenter.default.publisher(for: .coursepetForceLogout)) { _ in
            withAnimation {
                isLoggedIn = false
                skippedLogin = false   // 登出后回到登录页（而不是又跳过）
            }
        }
        // 登录页点"未配置服务器" / "已配置服务器" → 跳到设置页
        // 仅当用户已登录或游客模式进到主界面时才会触发（登录页本身就是登录态的反面）
        .onReceive(NotificationCenter.default.publisher(for: .coursepetOpenSettings)) { _ in
            if isLoggedIn || skippedLogin {
                // 与 mainTabs 里 SettingsView 的 .tag 保持同一算式：
                // 极简模式（关 AI）移掉聊聊 tab，设置 tag 从 4 上移到 3
                selectedTab = intelligentMode ? 4 : 3
            }
        }
        // 扫一扫全屏页：挂在最外层 Group，登录前后都可达（锁屏小组件冷启动也能直接进扫码）
        .fullScreenCover(isPresented: $showScanner) {
            ScanCodeView()
        }
    }

    /// App 启动时：如果 Keychain 里有 refresh_token，先静默换新 access_token。
    /// 成功 → 进主页；连不上（offline）→ 保留登录态照样进主页（业务层 401 时网络层会再兜底续）；
    /// 只有服务器明确拒绝（invalid，token 真失效已清 Keychain）→ 显示登录页。
    private func tryAutoRefresh() async {
        defer { autoRefreshing = false }
        guard isLoggedIn else { return }
        let server = AgentConfigStore.loadServerConfig()
        guard server.isConfigured else {
            // 没配服务器地址——没服务器可连，保持登录状态（端侧模式）
            return
        }
        if await AuthStore.refreshAccessToken(baseURL: server.baseURL) == .invalid {
            // refresh_token 已被服务器拒绝且清掉了——回登录页
            isLoggedIn = false
        }
    }

    // MARK: - 主 Tab

    @ViewBuilder
    private var mainTabs: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: $selectedTab) {
                NavigationStack {
                    ScheduleMainView()
                }
                .tabItem {
                    Label("课表", systemImage: "calendar")
                }
                .tag(0)

                TodoView()
                    .badge(dataManager.pendingCount > 0 ? Text("\(dataManager.pendingCount)") : nil)
                    .tabItem {
                        Label("事务", systemImage: "checklist")
                    }
                    .tag(1)

                // 聊聊 tab（Agent 聊天）：极简模式下隐藏（整个 tab 不挂载）
                if intelligentMode {
                    AgentChatView()
                        .tabItem {
                            Label("聊聊", systemImage: "message.fill")
                        }
                        .tag(2)
                }

                FocusView()
                    .tabItem {
                        Label("专注", systemImage: "timer")
                    }
                    // 极简模式下专注 tag 从 3 上移到 2（因为聊聊 tab 被移除）
                    .tag(intelligentMode ? 3 : 2)

                SettingsView()
                    .tabItem {
                        Label("设置", systemImage: "gearshape")
                    }
                    .tag(intelligentMode ? 4 : 3)
            }
            .tint(Color(.systemIndigo))

            // 全局下节课悬浮条：正在上课 / 课前 15 分钟内出现，点击跳课表 tab
            // 只在「事务」「设置」tab 显示——聊天页有输入框、专注页有计时环、
            // 课表页自己有下节课视图，这些 tab 底部都有常驻 UI，悬浮条会挡住
            let settingsTag = intelligentMode ? 4 : 3
            if selectedTab == 1 || selectedTab == settingsTag {
                NextCourseBanner(onTap: { selectedTab = 0 })
                    .padding(.bottom, 58)
            }
        }
        // 前台驻留期间每分钟检查一次：进入"课前 15 分钟"窗口或正在上课的课程
        // 自动上灵动岛（checkAndStartIfNeeded 幂等，已有同课程 Activity 时只会更新）
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in
            LiveActivityManager.checkAndStartIfNeeded()
        }
        // 小组件 / 灵动岛点击直达：coursepet://schedule|todo|feed|focus|settings
        // 快捷指令入口：coursepet://parcel?text=<URL编码的取件短信全文>（Shortcuts "收到短信"自动化调用）
        // 通知点击路由也汇入 handleDeepLink（NotificationRouter post 同名事件）
        .onOpenURL { url in
            handleDeepLink(url)
        }
        .onReceive(NotificationCenter.default.publisher(for: .coursepetOpenNotificationRoute)) { note in
            if let url = note.userInfo?["url"] as? URL {
                handleDeepLink(url)
            }
        }
    }

    /// 深链统一入口：小组件/灵动岛/聊天卡片/通知点击，都走这里切 tab
    private func handleDeepLink(_ url: URL) {
        // 极简模式下 tag 结构变了：聊聊 tab 被移除，后续 tag 上移
        let focusTag = intelligentMode ? 3 : 2
        let settingsTag = intelligentMode ? 4 : 3
        switch url.host {
        case "schedule": selectedTab = 0
        case "todo":     selectedTab = 1
        case "feed":     selectedTab = intelligentMode ? 2 : settingsTag   // 极简模式下聊聊 tab 不存在，跳设置页
        case "focus":    selectedTab = focusTag
        case "settings": selectedTab = settingsTag
        case "scan":     showScanner = true
        case "parcel":
            selectedTab = 1
            dataManager.pendingParcelSMS = Self.parcelPayload(from: url)
        default: break
        }
    }

    /// 从 coursepet://parcel?text=… 里抠出短信全文。
    /// 快捷指令拼 URL 时有三类常见坑，这里全部兜住：
    /// ① 参数名被换行/空白污染（"?\ntext=…"）→ 标准解析取不到，但 host 仍是 parcel，
    ///    表现为"能跳到快递但什么都不识别"；直接在原始串里找 text=
    /// ② 变量里的 % 被 Shortcuts 二次编码（%E3%80%90 变成 %25E3%25%80）→ 只解一次会得到
    ///    字面百分号，中文匹配不上；循环解码两层
    /// ③ 变量被插到了前缀之前，短信跑到 scheme 前面 → 取 coursepet:// 左侧那段
    private static func parcelPayload(from url: URL) -> String {
        if let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) == "text" })?
            .value,
           !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return decodeRepeatedly(value)
        }
        let raw = url.absoluteString
        if let range = raw.range(of: "text=") {
            let decoded = decodeRepeatedly(String(raw[range.upperBound...]))
            if !decoded.isEmpty { return decoded }
        }
        if let schemeRange = raw.range(of: "coursepet://") {
            let head = String(raw[..<schemeRange.lowerBound])
            if !head.isEmpty { return decodeRepeatedly(head) }
        }
        return ""
    }

    /// 循环 percent-decode（最多两层）：单层编码解一次即稳定，
    /// 双层编码也能还原成中文，且不会破坏本来就正常的文本
    private static func decodeRepeatedly(_ text: String) -> String {
        var out = text
        for _ in 0..<2 {
            guard let decoded = out.removingPercentEncoding, decoded != out else { break }
            out = decoded
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
