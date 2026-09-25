// MARK: - Live Activity 扩展入口（@main，整个模块只能有一个）
import WidgetKit
import SwiftUI

@main
struct CoursePetLiveActivityApp: WidgetBundle {
    var body: some Widget {
        CoursePetLiveActivity()
        FocusLiveActivity()   // 专注计时灵动岛
    }
}
