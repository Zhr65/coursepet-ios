// MARK: - 液态玻璃质感（iOS 17 手搓版）
// 玻璃态的灵魂在玻璃后面有东西：自定义背景图（用户选照片）> 默认柔和渐变云。
// 设计原则：半透+模糊让玻璃呼吸 / 细描边+弱阴影强化质感 / 信息做减法。
import SwiftUI
import UIKit
import PhotosUI

// MARK: - 自定义背景存储：选中的照片落盘 Documents，启动时加载
@MainActor
final class GlassBackground: ObservableObject {
    static let shared = GlassBackground()
    @Published var image: UIImage?

    private var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("glass-background.jpg")
    }

    private init() {
        if let data = try? Data(contentsOf: fileURL), let img = UIImage(data: data) {
            image = img
        }
    }

    func save(_ newImage: UIImage) {
        // 压缩存储：最长边 1600 + JPEG 0.82，背景图不需要原画质的内存
        let longest = max(newImage.size.width, newImage.size.height)
        var scaled = newImage
        if longest > 1600, let cg = newImage.cgImage {
            let factor = 1600 / longest
            let newSize = CGSize(width: newImage.size.width * factor, height: newImage.size.height * factor)
            scaled = UIGraphicsImageRenderer(size: newSize).image { _ in
                UIImage(cgImage: cg, scale: 1, orientation: newImage.imageOrientation)
                    .draw(in: CGRect(origin: .zero, size: newSize))
            }
        }
        if let data = scaled.jpegData(compressionQuality: 0.82) {
            try? data.write(to: fileURL, options: .atomic)
            image = scaled
        }
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
        image = nil
    }
}

// MARK: - 页面背景层：自定义照片（轻压暗保可读性）或默认霞色渐变云
struct GlassBackdrop: View {
    @ObservedObject private var bg = GlassBackground.shared
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            if let img = bg.image {
                GeometryReader { geo in
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                }
                .overlay(scheme == .dark ? Color.black.opacity(0.38) : Color.black.opacity(0.10))
            } else {
                defaultGradient
            }
        }
        .ignoresSafeArea()
    }

    /// 默认背景：四角霞色渐变云（粉橙/桃/薰衣草/天蓝），深色模式自动压暗
    private var defaultGradient: some View {
        ZStack {
            (scheme == .dark
             ? Color(red: 0.09, green: 0.09, blue: 0.13)
             : Color(red: 1.00, green: 0.965, blue: 0.945))
            RadialGradient(colors: [Color(red: 1.00, green: 0.73, blue: 0.60).opacity(scheme == .dark ? 0.32 : 0.50), .clear],
                           center: UnitPoint(x: 0.10, y: 0.05), startRadius: 0, endRadius: 520)
            RadialGradient(colors: [Color(red: 1.00, green: 0.62, blue: 0.72).opacity(scheme == .dark ? 0.28 : 0.42), .clear],
                           center: UnitPoint(x: 0.95, y: 0.15), startRadius: 0, endRadius: 480)
            RadialGradient(colors: [Color(red: 0.64, green: 0.62, blue: 1.00).opacity(scheme == .dark ? 0.28 : 0.36), .clear],
                           center: UnitPoint(x: 0.05, y: 0.90), startRadius: 0, endRadius: 500)
            RadialGradient(colors: [Color(red: 0.55, green: 0.80, blue: 1.00).opacity(scheme == .dark ? 0.22 : 0.30), .clear],
                           center: UnitPoint(x: 0.95, y: 0.95), startRadius: 0, endRadius: 460)
        }
    }
}

extension View {
    /// 玻璃页底：隐藏系统列表底色 + 铺 GlassBackdrop（自定义照片或渐变云）
    func glassPage() -> some View {
        scrollContentBackground(.hidden)
            .background(GlassBackdrop())
    }

    /// 卡片级玻璃板（v6 对照 mineradio 实拍：磨砂减半、背景 vivid 透过、烟色随背景）
    func liquidGlass(cornerRadius: CGFloat = 26, tint: Color = Color(.systemBackground)) -> some View {
        background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.ultraThinMaterial)
                .opacity(0.55)                          // 关键：磨砂减半，背景几乎原样透出
                .overlay(Color.black.opacity(0.06))     // 轻烟色
                .overlay(Color.white.opacity(0.05))     // 微提亮（≈brightness 1.16）
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.28), lineWidth: 1)
                        .blur(radius: 0.8))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 4)
                        .blur(radius: 2.2))
                .shadow(color: Color(red: 0.07, green: 0.07, blue: 0.10).opacity(0.04), radius: 10, x: 0, y: 5)
                .shadow(color: Color(red: 0.07, green: 0.07, blue: 0.10).opacity(0.04), radius: 22, x: 0, y: 12)
        )
    }

    /// 列表行玻璃底（v6 同款减淡）
    func glassListRow(tint: Color = Color(.systemBackground)) -> some View {
        listRowBackground(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.ultraThinMaterial)
                .opacity(0.50)
                .overlay(Color.black.opacity(0.04))
                .overlay(Color.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.24), lineWidth: 1)
                        .blur(radius: 0.8))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 3)
                        .blur(radius: 2))
                .shadow(color: Color(red: 0.07, green: 0.07, blue: 0.10).opacity(0.04), radius: 8, x: 0, y: 4)
                .padding(.vertical, 5)
        )
    }
}

/// 玻璃按钮：与卡片同一套光影语言；按压回缩+变暗+阴影收紧
extension View {
    /// iOS 16 兼容：清零 insetGrouped 列表顶部系统留白（17+ 走 contentMargins，16 无对应 API 原样返回）
    @ViewBuilder func zeroTopListMargin() -> some View {
        if #available(iOS 17.0, *) {
            self.contentMargins(.top, 0, for: .scrollContent)
        } else {
            self
        }
    }
}

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
                    .opacity(0.55)
                    .overlay(Color.black.opacity(configuration.isPressed ? 0.12 : 0.07))
                    .overlay(Color.white.opacity(0.05))
                    .overlay(
                        Capsule()
                            .strokeBorder(Color.white.opacity(configuration.isPressed ? 0.36 : 0.28), lineWidth: 1)
                            .blur(radius: 0.8))
                    .overlay(
                        Capsule()
                            .strokeBorder(Color.white.opacity(0.10), lineWidth: 3)
                            .blur(radius: 2))
                    .shadow(color: Color(red: 0.07, green: 0.07, blue: 0.10).opacity(configuration.isPressed ? 0.08 : 0.14),
                            radius: configuration.isPressed ? 10 : 14, x: 0, y: configuration.isPressed ? 5 : 8)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

// MARK: - 设置页「自定义背景」行：选照片 / 恢复默认
struct GlassBackgroundPicker: View {
    @State private var selection: PhotosPickerItem?
    @ObservedObject private var bg = GlassBackground.shared

    var body: some View {
        HStack {
            Label("自定义背景", systemImage: "photo")
            Spacer()
            if bg.image != nil {
                Button("恢复默认") { bg.clear() }
                    .font(.caption)
            }
            PhotosPicker(selection: $selection, matching: .images) {
                Text("选张图").font(.subheadline)
            }
        }
        .onChange(of: selection) { item in
            guard let item else { return }
            Task { @MainActor in
                if let data = try? await item.loadTransferable(type: Data.self),
                   let img = UIImage(data: data) {
                    GlassBackground.shared.save(img)
                }
                selection = nil
            }
        }
    }
}

/// Apple 设置风格的行头图标：彩色圆角方块 + 白色符号，统一每行的视觉语言（正式感的关键）
struct SettingIcon: View {
    var color: Color
    var systemImage: String
    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(.white)
            .frame(width: 28, height: 28)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(LinearGradient(colors: [color, color.opacity(0.72)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .shadow(color: color.opacity(0.30), radius: 3, y: 1)
            )
    }
}

enum GlassChrome {
    /// 全局导航栏 / 标签栏玻璃化（UIKit appearance，App 启动时调用一次）
    static func install() {
        // 白底透明度压低：让自定义照片从导航/标签栏后透出来（浓白底会盖成灰白留空）
        let tab = UITabBarAppearance()
        tab.configureWithTransparentBackground()
        tab.backgroundEffect = UIBlurEffect(style: .systemUltraThinMaterial)
        tab.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.08)
        tab.shadowColor = .clear
        tab.shadowImage = UIImage()
        UITabBar.appearance().standardAppearance = tab
        UITabBar.appearance().scrollEdgeAppearance = tab

        let nav = UINavigationBarAppearance()
        nav.configureWithTransparentBackground()
        nav.backgroundEffect = UIBlurEffect(style: .systemUltraThinMaterial)
        nav.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.06)
        nav.shadowColor = .clear
        nav.shadowImage = UIImage()
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav
        UINavigationBar.appearance().compactAppearance = nav
    }
}
