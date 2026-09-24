// MARK: - Live Activity 入口文件（供 XcodeGen 引用）
import ActivityKit
import SwiftUI
import WidgetKit

// 主入口（App Extension 必须有一个 @main）
@main
struct CoursePetLiveActivityApp: App {
    var body: some Scene {
        LiveActivityBundle()
    }
}
