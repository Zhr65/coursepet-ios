// MARK: - CoursePet 主 App（含 Live Activity 启动检查）
import SwiftUI
import ActivityKit

@main
struct CoursePetApp: App {
    @StateObject private var dataManager = DataManager.shared

    init() {
        // 启动时把 Bundle 内置的宠物 PNG 帧安装到 App Group 容器（已装过则跳过），
        // 这样主 App / Widget / 灵动岛都会优先显示真实形象图而不是程序化兜底宠物
        PetAssetInstaller.installIfNeeded()
        // 主 App 启动时注入数据保存钩子：每次保存/清空数据后重建本地课程提醒通知。
        // DataManager 在 Shared 中不能引用主 App 类型，故用静态钩子解耦；
        // Widget / Live Activity 扩展进程中该钩子保持 nil，不影响扩展。
        DataManager.onStateSaved = {
            NotificationManager.refreshAll()
            // 数据变化（加/删课程等）后立即检查：若新课程已在课前 15 分钟窗口内，马上上灵动岛
            LiveActivityManager.checkAndStartIfNeeded()
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(dataManager)
                // darkMode 是 DataManager 的 @Published 属性，切换设置后立即生效
                .preferredColorScheme(dataManager.darkMode ? .dark : .light)
        }
        .onChange(of: UIApplication.shared.applicationState) { newState in
            if newState == .active {
                // App 回到前台时检查是否需要启动 Live Activity
                LiveActivityManager.checkAndStartIfNeeded()
                // App 回到前台：按最新课表重建未来 7 天的课程提醒通知
                NotificationManager.refreshAll()
                // 彩蛋成就：早上 8 点前打开 App 解锁「早起鸟」（静默解锁，成就墙可见）
                if Calendar.current.component(.hour, from: Date()) < 8 {
                    AchievementManager.unlockIfNeeded("early_bird")
                }
            }
        }
    }
}

// MARK: - 主界面 TabView
struct ContentView: View {
    @EnvironmentObject var dataManager: DataManager
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                ScheduleMainView()
            }
            .tabItem {
                // 注意：tab 图标固定不动态切换（iOS 16 上三元换 symbol 会丢图标）
                Label("课表", systemImage: "calendar")
            }
            .tag(0)

            // TodoView 自带 NavigationStack，这里直接放置
            TodoView()
                // 角标显示未完成作业数（0 时系统自动隐藏）
                .badge(dataManager.pendingCount > 0 ? Text("\(dataManager.pendingCount)") : nil)
                .tabItem {
                    Label("待办", systemImage: "checklist")
                }
                .tag(1)

            FeedView()
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
        // 前台驻留期间每分钟检查一次：进入"课前 15 分钟"窗口或正在上课的课程
        // 自动上灵动岛（checkAndStartIfNeeded 幂等，已有同课程 Activity 时只会更新）
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in
            LiveActivityManager.checkAndStartIfNeeded()
        }
        // 小组件 / 灵动岛点击直达：coursepet://schedule|todo|feed|focus|settings
        .onOpenURL { url in
            switch url.host {
            case "schedule": selectedTab = 0
            case "todo":     selectedTab = 1
            case "feed":     selectedTab = 2
            case "focus":    selectedTab = 3
            case "settings": selectedTab = 4
            default: break
            }
        }
    }
}
