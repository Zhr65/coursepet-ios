// MARK: - 液态玻璃质感（iOS 17 手搓版）
// 系统原生 glassEffect（Liquid Glass）要 iOS 26 才有，真机 iOS 17.7 用不了；
// 按设计四原则手搓等效：
//   ① 分层光影是灵魂：左上柔和高光（反光）+ 右下大半径阴影（厚度）+ 中间渐变过渡
//   ② 底色呼应不"飘"：玻璃底叠页面主色半透明层，与背景融为一体不是悬浮贴纸
//   ③ 圆弧柔起来：全程连续曲率（Apple 圆角），光影沿圆角柔和过渡
//   ④ 细节纹理加层次：对角高光带磨砂纹理，玻璃从光滑平面变有质感实体
import SwiftUI

extension View {
    /// 卡片级玻璃板。tint 传当前页面的背景主色（底色呼应原则②）
    func liquidGlass(cornerRadius: CGFloat = 20, tint: Color = Color(.systemBackground)) -> some View {
        background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.ultraThinMaterial)
                // ② 底色呼应：页面主色低透明叠加，玻璃"长"在背景上
                .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(tint.opacity(0.18)))
                // ④ 磨砂纹理：对角高光带（左上亮→右下收），模拟实体反光
                .overlay(
                    LinearGradient(colors: [.white.opacity(0.30), .white.opacity(0.06),
                                            .clear, .white.opacity(0.10)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                        .blendMode(.plusLighter)
                )
                // ① 左上高光描边（玻璃棱边反光），右下角描边略强形成光感层次
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(
                            LinearGradient(colors: [.white.opacity(0.80), .white.opacity(0.14),
                                                    .white.opacity(0.32)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing),
                            lineWidth: 1)
                )
                // ① 右下主投影（厚度）+ 左上极淡环境影（把卡片"压"回页面）
                .shadow(color: .black.opacity(0.14), radius: 16, x: 4, y: 8)
                .shadow(color: .black.opacity(0.05), radius: 6, x: -2, y: -3)
        )
    }

    /// 列表行玻璃底（轻量版，无投影不抢层级）
    func glassListRow(tint: Color = Color(.systemBackground)) -> some View {
        listRowBackground(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(tint.opacity(0.15)))
                .overlay(
                    LinearGradient(colors: [.white.opacity(0.22), .clear, .white.opacity(0.07)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                        .blendMode(.plusLighter))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(.white.opacity(0.45), lineWidth: 0.8))
                .padding(.vertical, 3)
        )
    }
}

/// 玻璃按钮：与卡片同一套光影语言；按压回缩+变暗+阴影收紧（"好按"的手感）
struct GlassButtonStyle: ButtonStyle {
    var tint: Color = .accentColor
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundColor(.primary)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(
                Capsule()
                    .fill(.ultraThinMaterial)
                    // ② 底色呼应：tint 半透填充，按压时加深
                    .overlay(Capsule().fill(tint.opacity(configuration.isPressed ? 0.34 : 0.16)))
                    // ④ 磨砂纹理
                    .overlay(
                        LinearGradient(colors: [.white.opacity(0.30), .clear, .white.opacity(0.10)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                            .blendMode(.plusLighter))
                    // ① 左上高光描边
                    .overlay(
                        Capsule().strokeBorder(
                            LinearGradient(colors: [.white.opacity(0.85), .white.opacity(0.20)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing),
                            lineWidth: 1))
                    // ① 右下阴影（按压收紧密度感）
                    .shadow(color: .black.opacity(configuration.isPressed ? 0.06 : 0.14),
                            radius: configuration.isPressed ? 4 : 10,
                            x: configuration.isPressed ? 1 : 2,
                            y: configuration.isPressed ? 2 : 5)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: configuration.isPressed)
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
