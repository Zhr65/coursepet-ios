// MARK: - CoursePet 主 App（含 Live Activity 启动检查）
import SwiftUI
import ActivityKit
import Shared

@main
struct CoursePetApp: App {
    @StateObject private var dataManager = DataManager.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(dataManager)
                .preferredColorScheme(dataManager.isDarkMode ? .dark : .light)
        }
        .onChange(of: UIApplication.shared.applicationState) { newState in
            if newState == .active {
                // App 回到前台时检查是否需要启动 Live Activity
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
        TabView(selection: $selectedTab) {
            NavigationStack {
                ScheduleMainView()
            }
            .tabItem {
                Label("课表", systemImage: selectedTab == 0 ? "calendar.fill" : "calendar")
            }
            .tag(0)

            FeedView()
                .tabItem {
                    Label("养成", systemImage: selectedTab == 1 ? "heart.fill" : "heart")
                }
                .tag(1)

            GameView()
                .tabItem {
                    Label("游戏", systemImage: selectedTab == 2 ? "gamecontroller.fill" : "gamecontroller")
                }
                .tag(2)

            SettingsView()
                .tabItem {
                    Label("设置", systemImage: selectedTab == 3 ? "gearshape.fill" : "gearshape")
                }
                .tag(3)
        }
        .tint(Color(.systemIndigo))
    }
}
