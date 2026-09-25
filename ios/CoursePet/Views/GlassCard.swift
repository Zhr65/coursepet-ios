// MARK: - 全局液态玻璃卡片容器（统一各 tab 的卡片风格）
import SwiftUI

/// 液态玻璃卡片：超薄材质背景（.ultraThinMaterial，深色模式自动变暗）+ 20pt 圆角
/// + 白色半透明 1pt 描边 + 柔和阴影；玻璃材质能透出页面背景的渐变色
struct GlassCard<Content: View>: View {
    let cornerRadius: CGFloat
    let padding: CGFloat
    let content: Content

    init(cornerRadius: CGFloat = 20, padding: CGFloat = 16, @ViewBuilder content: () -> Content) {
        self.cornerRadius = cornerRadius
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(Color.white.opacity(0.5), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
    }
}

// MARK: - List 玻璃行辅助（配合 scrollContentBackground(.hidden) 使用）
extension View {
    /// 给 List 行套上液态玻璃背景（SettingsView / TodoView 等基于 List 的页面用）。
    /// 用法：Section { Group { 各行 }.glassListRow() }，Group 会把修饰符传播给每一行。
    func glassListRow() -> some View {
        listRowBackground(
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.white.opacity(0.4), lineWidth: 0.5)
                )
        )
    }
}

// MARK: - 各 tab 柔和渐变背景色板（浅色系，玻璃卡透出）
enum PagePalette {
    /// 养成页：粉紫
    static let feed = [
        Color(red: 0.99, green: 0.91, blue: 0.94),
        Color(red: 0.87, green: 0.88, blue: 0.99)
    ]
    /// 专注页：蓝紫
    static let focus = [
        Color(red: 0.87, green: 0.92, blue: 0.99),
        Color(red: 0.91, green: 0.87, blue: 0.99)
    ]
    /// 待办页：靛青
    static let todo = [
        Color(red: 0.88, green: 0.91, blue: 0.99),
        Color(red: 0.84, green: 0.93, blue: 0.97)
    ]
    /// 设置页：灰蓝
    static let settings = [
        Color(red: 0.90, green: 0.90, blue: 0.94),
        Color(red: 0.85, green: 0.88, blue: 0.95)
    ]
}
