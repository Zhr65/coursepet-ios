// MARK: - 通用 Widget 背景（深色模式适配）
import SwiftUI
import WidgetKit

extension View {
    /// 为 Widget 提供背景，自动适配深色/浅色模式
    func widgetBackground(_ backgroundView: some View) -> some View {
        if #available(iOS 17.0, *) {
            return containerBackground(for: .widget) {
                backgroundView
            }
        } else {
            return background(backgroundView)
        }
    }
}

// MARK: - 定时刷新扩展（ScheduleView 用）
import Combine

extension View {
    /// 每 60 秒刷新一次（用于课表倒计时更新）
    func periodicTimer() -> some View {
        return modifier(PeriodicTimerModifier())
    }
}

struct PeriodicTimerModifier: ViewModifier {
    @State private var tick: Int = 0

    func body(content: Content) -> some View {
        content
            .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in
                withAnimation { tick += 1 }
            }
            .id(tick)
    }
}
