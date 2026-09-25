// MARK: - CoursePet 主 App（含 Live Activity 启动检查）
import SwiftUI
import ActivityKit

@main
struct CoursePetApp: App {
    @StateObject private var dataManager = DataManager.shared

    init() {
        // 主 App 启动时注入数据保存钩子：每次保存/清空数据后重建本地课程提醒通知。
        // DataManager 在 Shared 中不能引用主 App 类型，故用静态钩子解耦；
        // Widget / Live Activity 扩展进程中该钩子保持 nil，不影响扩展。
        DataManager.onStateSaved = { NotificationManager.refreshAll() }
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
                Label("课表", systemImage: selectedTab == 0 ? "calendar.fill" : "calendar")
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
                    Label("养成", systemImage: selectedTab == 2 ? "heart.fill" : "heart")
                }
                .tag(2)

            // FocusView：专注番茄钟（替换原游戏 tab；GameView.swift 保留但不再挂载）
            FocusView()
                .tabItem {
                    Label("专注", systemImage: selectedTab == 3 ? "timer.fill" : "timer")
                }
                .tag(3)

            SettingsView()
                .tabItem {
                    Label("设置", systemImage: selectedTab == 4 ? "gearshape.fill" : "gearshape")
                }
                .tag(4)
        }
        .tint(Color(.systemIndigo))
    }
}
