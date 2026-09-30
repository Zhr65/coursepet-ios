// MARK: - CoursePet 主 App（含 Live Activity 启动检查）
import SwiftUI
import ActivityKit
import UserNotifications

@main
struct CoursePetApp: App {
    @StateObject private var dataManager = DataManager.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // 启动时把 Bundle 内置的宠物 PNG 帧安装到 App Group 容器（已装过则跳过），
        // 这样主 App / Widget / 灵动岛都会优先显示真实形象图而不是程序化兜底宠物
        PetAssetInstaller.installIfNeeded()
        // 冷启动清理：杀后台后系统里的专注灵动岛 Activity 不会自动移除（会继续计时），
        // 而专注状态只存内存、重开必然丢失 —— 启动时清掉这种孤儿活动，与用户预期一致
        FocusActivityManager.cleanupOrphansOnLaunch()
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
        // 位置提醒：冷启动重建地理围栏（幂等，可重复调用）
        LocationReminderManager.shared.bootstrap()
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
                // App 回到前台时检查是否需要启动 Live Activity
                LiveActivityManager.checkAndStartIfNeeded()
                // App 回到前台：按最新课表重建未来 7 天的课程提醒通知
                NotificationManager.refreshAll()
                // 定时任务结果拉取（Muse 式异步任务；60s 内部节流，严禁挂 refreshAll 链）
                NotificationManager.refreshAgentTasks()
                // 位置提醒：回前台重建围栏（手动杀掉 App 导致围栏失效后自愈）
                LocationReminderManager.shared.bootstrap()
                // 彩蛋成就：早上 8 点前打开 App 解锁「早起鸟」（静默解锁，成就墙可见）
                if Calendar.current.component(.hour, from: Date()) < 8 {
                    AchievementManager.unlockIfNeeded("early_bird")
                }
            default:
                // 退后台过渡（inactive/background）：iOS 16.1 只有前台能启动灵动岛，
                // 趁还没完全后台抢最后时机检查一次，覆盖"退出 App 前课程已进入 15 分钟窗口"的场景
                LiveActivityManager.checkAndStartIfNeeded()
            }
        }
    }
}

// MARK: - 主界面 TabView
struct ContentView: View {
    @EnvironmentObject var dataManager: DataManager
    @State private var selectedTab = 0

    var body: some View {
        // ZStack 挂全局「下节课」悬浮条：任意页面底部可见，点击跳课表
        ZStack(alignment: .bottom) {
            TabView(selection: $selectedTab) {
                NavigationStack {
                    ScheduleMainView()
                }
                .tabItem {
                    // 注意：tab 图标固定不动态切换（iOS 16 上三元换 symbol 会丢图标）
                    Label("课表", systemImage: "calendar")
                }
                .tag(0)

                // TodoView 事务页（作业/快递/记账三分段）自带 NavigationStack，这里直接放置
                TodoView()
                    // 角标显示未完成作业数（0 时系统自动隐藏）
                    .badge(dataManager.pendingCount > 0 ? Text("\(dataManager.pendingCount)") : nil)
                    .tabItem {
                        Label("事务", systemImage: "checklist")
                    }
                    .tag(1)

                // 养成 tab 主位换成大聊天界面（Muse 形态：打开 App 就是和宠物聊）；
                // AgentChatView 自带 NavigationStack，直接做 tab 内容。
                // 喂食/签到/步数/成就等养成功能收进聊天页右上「更多 → 养成中心」。
                AgentChatView()
                    .tabItem {
                        Label("养成", systemImage: "heart")
                    }
                    .tag(2)

                // FocusView：专注番茄钟（替换原游戏 tab；GameView.swift 保留但不再挂载）
                FocusView()
                    .tabItem {
                        Label("专注", systemImage: "timer")
                    }
                    .tag(3)

                SettingsView()
                    .tabItem {
                        Label("设置", systemImage: "gearshape")
                    }
                    .tag(4)
            }
            .tint(Color(.systemIndigo))

            // 全局下节课悬浮条：正在上课 / 课前 15 分钟内出现，点击跳课表 tab
            NextCourseBanner(onTap: { selectedTab = 0 })
                // 抬高到 tab bar 上方（tab bar 约 49pt + 安全区由系统处理）
                .padding(.bottom, 58)
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
        switch url.host {
        case "schedule": selectedTab = 0
        case "todo":     selectedTab = 1
        case "feed":     selectedTab = 2
        case "focus":    selectedTab = 3
        case "settings": selectedTab = 4
        case "parcel":
            selectedTab = 1
            // 解出短信全文交给 ParcelSection 弹预填层（解析在弹层内完成，URL 只做搬运）
            if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
               let text = components.queryItems?.first(where: { $0.name == "text" })?.value,
               !text.isEmpty {
                dataManager.pendingParcelSMS = text
            }
        default: break
        }
    }
}
