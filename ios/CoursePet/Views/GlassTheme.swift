// MARK: - 液态玻璃质感（iOS 17 手搓版）
// 系统原生 glassEffect（Liquid Glass）要 iOS 26 才有，真机是 iOS 17.7 用不了；
// 这套等效组合拳在 iOS 16+ 出同样的味：
//   超薄模糊材质（ultraThinMaterial，自带饱和度提升）
//   + 左上→右下的白色渐变发丝描边（玻璃高光）
//   + 大半径低强度投影（悬浮感）+ 连续圆角（Apple 曲率）
import SwiftUI

extension View {
    /// 卡片级玻璃板：用于内容卡片 / 弹窗内板
    func liquidGlass(cornerRadius: CGFloat = 20) -> some View {
        background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(
                            LinearGradient(colors: [.white.opacity(0.65), .white.opacity(0.12)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing),
                            lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.10), radius: 14, x: 0, y: 6)
        )
    }
}

enum GlassChrome {
    /// 全局导航栏 / 标签栏玻璃化（UIKit appearance，App 启动时调用一次）
    /// 半透明材质叠在内容上，滚动时内容从玻璃后透出，即"液态玻璃"的通透观感
    static func install() {
        let tab = UITabBarAppearance()
        tab.configureWithTransparentBackground()
        tab.backgroundEffect = UIBlurEffect(style: .systemUltraThinMaterial)
        tab.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.55)
        tab.shadowColor = .clear
        tab.shadowImage = UIImage()
        UITabBar.appearance().standardAppearance = tab
        UITabBar.appearance().scrollEdgeAppearance = tab

        let nav = UINavigationBarAppearance()
        nav.configureWithTransparentBackground()
        nav.backgroundEffect = UIBlurEffect(style: .systemUltraThinMaterial)
        nav.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.45)
        nav.shadowColor = .clear
        nav.shadowImage = UIImage()
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav
        UINavigationBar.appearance().compactAppearance = nav
    }
}
