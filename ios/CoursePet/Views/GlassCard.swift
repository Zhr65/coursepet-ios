// MARK: - 全局液态玻璃卡片容器（统一各 tab 的卡片风格）
import SwiftUI

/// 液态玻璃卡片：质感档位跟随设置页「玻璃质感」（GlassSurface @AppStorage 驱动，换档全 App 实时生效）
/// + 20pt 圆角 + 柔和阴影；玻璃材质能透出页面背景的渐变色
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
            .background(GlassSurface(cornerRadius: cornerRadius))
    }
}

// MARK: - List 玻璃行辅助（配合 scrollContentBackground(.hidden) 使用）
extension View {
    /// 给 List 行套上液态玻璃背景（TodoView / TransactionSections 等基于 List 的页面用）。
    /// 走 listRowBackground 通道（List 渲染行底的正路，间距不被吞）+ GlassSurface 档位跟随。
    func glassListRow() -> some View {
        listRowBackground(
            GlassSurface(cornerRadius: 12)
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
