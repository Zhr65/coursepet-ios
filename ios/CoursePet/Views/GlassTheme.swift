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

// MARK: - 玻璃质感总控：档位存储 + 各组件读取的单一事实源
enum GlassTheme { }

// MARK: - 玻璃质感 DIY：七档可切换（设置页 → 外观 → 玻璃质感）
enum GlassStyle: String, CaseIterable, Identifiable {
    case thin     // 薄玻璃：磨砂减半，背景 vivid 透过（v6）
    case frost    // 毛玻璃贴片：浓雾整片（deepseek 截图那种）
    case smoke    // 烟玻璃：深色烟感，沉稳（mineradio 暗色播放条）
    case crystal  // 水晶：极透 + 亮边勾勒
    case amber    // 琥珀·日落：暖橙色调，夕阳透磨砂
    case obsidian // 暗夜·黑曜：纯黑暗色，亮边勾边
    case aurora   // 极光·Aurora：青紫渐变晕，活泼流动

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .thin: return "薄玻璃"
        case .frost: return "毛玻璃贴片"
        case .smoke: return "烟玻璃"
        case .crystal: return "水晶"
        case .amber: return "琥珀·日落"
        case .obsidian: return "暗夜·黑曜"
        case .aurora: return "极光·Aurora"
        }
    }
    var icon: String {
        switch self {
        case .thin: return "rectangle.on.rectangle"
        case .frost: return "square.fill"
        case .smoke: return "moon.haze.fill"
        case .crystal: return "diamond"
        case .amber: return "sun.max.fill"
        case .obsidian: return "moon.fill"
        case .aurora: return "sparkles"
        }
    }
}

extension GlassTheme {
    static var style: GlassStyle {
        get { GlassStyle(rawValue: UserDefaults.standard.string(forKey: "glass.style") ?? "") ?? .thin }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "glass.style") }
    }
}

// MARK: - 玻璃面板本体（@AppStorage 驱动）
// 之前换质感没反应的根因：GlassTheme.style 直读 UserDefaults 不可观察，选完没有视图被告知重绘。
// @AppStorage 监听同一个 key，任何档位写入 → 全 App 玻璃面板实时重绘。
struct GlassSurface: View {
    var cornerRadius: CGFloat = 18
    var capsule: Bool = false
    @AppStorage("glass.style") private var styleRaw = GlassStyle.thin.rawValue
    private var style: GlassStyle { GlassStyle(rawValue: styleRaw) ?? .thin }

    var body: some View {
        Group {
            if capsule {
                shapeBody(Capsule())
            } else {
                shapeBody(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            }
        }
        .shadow(color: Color(red: 0.07, green: 0.07, blue: 0.10).opacity(shadow), radius: 8, x: 0, y: 4)
    }

    /// 档位底色 + 描边。拆成 ZStack 两段拼（填充 / 细描边）——
    /// 七层修饰符在泛型 Shape 上叠加时 Codemagic 编译器类型检查超时（两次踩坑），
    /// 必须每段独立成短链，勿合并回长修饰链。
    /// 描边不加 blur：模糊会让高光在直边清晰、圆角处弥散，视觉上多出
    /// 一层"长方体内框"（双层轮廓错觉），故只留贴合 shape 的实线描边。
    private func shapeBody<S: InsettableShape>(_ shape: S) -> some View {
        ZStack {
            // 1) 填充层：材质 + 透明度 + 暗化/白化 + 色调叠加（琥珀橙 / 极光青紫渐变）
            shape
                .fill(material)
                .opacity(fillOpacity)
                .overlay(Color.black.opacity(blackTint))
                .overlay(Color.white.opacity(whiteTint))
                .overlay(accentOverlay)

            // 2) 细描边：1pt 白色实线（贴合圆角，无辉光层）
            shape
                .strokeBorder(Color.white.opacity(rim), lineWidth: 1)
        }
    }

    /// 色调叠加层：琥珀加暖橙、极光加青紫径向渐变、其余档位不加
    @ViewBuilder
    private var accentOverlay: some View {
        switch style {
        case .amber:
            Color.orange.opacity(0.18)
        case .aurora:
            RadialGradient(colors: [Color(red: 0.30, green: 0.82, blue: 0.92).opacity(0.24),
                                    Color(red: 0.55, green: 0.45, blue: 0.95).opacity(0.20),
                                    .clear],
                           center: UnitPoint(x: 0.20, y: 0.05), startRadius: 0, endRadius: 280)
        default:
            Color.clear
        }
    }

    private var material: AnyShapeStyle {
        switch style {
        case .frost: return AnyShapeStyle(.regularMaterial)
        default: return AnyShapeStyle(.ultraThinMaterial)
        }
    }
    private var fillOpacity: Double {
        switch style {
        case .thin: return 0.50
        case .frost: return 1.0
        case .smoke: return 0.80
        case .crystal: return 0.22
        case .amber: return 0.55
        case .obsidian: return 0.90
        case .aurora: return 0.55
        }
    }
    private var blackTint: Double {
        switch style {
        case .thin: return 0.04
        case .frost: return 0
        case .smoke: return 0.17
        case .crystal: return 0.01
        case .amber: return 0.04
        case .obsidian: return 0.28
        case .aurora: return 0.04
        }
    }
    private var whiteTint: Double {
        switch style {
        case .thin: return 0.04
        case .frost: return 0.12
        case .smoke: return 0.02
        case .crystal: return 0.06
        case .amber: return 0.03
        case .obsidian: return 0
        case .aurora: return 0.03
        }
    }

    private var rim: Double {
        switch style {
        case .thin: return 0.28
        case .frost: return 0.50
        case .smoke: return 0.22
        case .crystal: return 0.55
        case .amber: return 0.32
        case .obsidian: return 0.55
        case .aurora: return 0.30
        }
    }
    private var shadow: Double {
        switch style {
        case .thin: return 0.04
        case .frost: return 0.09
        case .smoke: return 0.07
        case .crystal: return 0.03
        case .amber: return 0.05
        case .obsidian: return 0.10
        case .aurora: return 0.05
        }
    }
}

extension View {
    /// 玻璃页底：隐藏系统列表底色 + 铺 GlassBackdrop（自定义照片或渐变云）
    func glassPage() -> some View {
        scrollContentBackground(.hidden)
            .background(GlassBackdrop())
    }

    /// 卡片级玻璃板：GlassSurface 承担全部质感（@AppStorage 驱动，换档全 App 实时生效）
    func liquidGlass(cornerRadius: CGFloat = 26, tint: Color = Color(.systemBackground)) -> some View {
        background(GlassSurface(cornerRadius: cornerRadius))
    }

    /// VStack/ScrollView 行卡（设置页等非 List 布局用）：间距是纯布局算术，无任何系统行为参与
    func glassRowCard() -> some View {
        self
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(GlassSurface(cornerRadius: 18))
            .padding(.bottom, 8)          // 相邻卡片之间的真缝隙（直接透出背景，系统行为吞不掉）
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
    // @AppStorage 驱动：换质感档位时按钮玻璃实时跟随（直读 UserDefaults 不可观察，是"换档没反应"的同款根因）
    @AppStorage("glass.style") private var styleRaw = GlassStyle.thin.rawValue
    private var style: GlassStyle { GlassStyle(rawValue: styleRaw) ?? .thin }
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundColor(.primary)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(
                Group {
                    switch style {
                    case .thin:
                        Capsule().fill(.ultraThinMaterial)
                            .opacity(0.55)
                            .overlay(Color.black.opacity(configuration.isPressed ? 0.12 : 0.07))
                            .overlay(Color.white.opacity(0.05))
                    case .frost:
                        Capsule().fill(.regularMaterial)
                            .overlay(Color.white.opacity(0.12))
                    case .smoke:
                        Capsule().fill(.ultraThinMaterial)
                            .opacity(0.85)
                            .overlay(Color.black.opacity(configuration.isPressed ? 0.26 : 0.18))
                            .overlay(Color.white.opacity(0.02))
                    case .crystal:
                        Capsule().fill(.ultraThinMaterial)
                            .opacity(0.25)
                            .overlay(Color.white.opacity(0.06))
                    case .amber:
                        Capsule().fill(.ultraThinMaterial)
                            .opacity(0.58)
                            .overlay(Color.black.opacity(0.04))
                            .overlay(Color.orange.opacity(0.14))
                            .overlay(Color.white.opacity(0.03))
                    case .obsidian:
                        Capsule().fill(.ultraThinMaterial)
                            .opacity(0.92)
                            .overlay(Color.black.opacity(0.22))
                    case .aurora:
                        Capsule().fill(.ultraThinMaterial)
                            .opacity(0.58)
                            .overlay(Color.black.opacity(0.04))
                            .overlay(
                                RadialGradient(colors: [Color(red: 0.30, green: 0.82, blue: 0.92).opacity(0.18),
                                                        Color(red: 0.55, green: 0.45, blue: 0.95).opacity(0.15),
                                                        .clear],
                                               center: UnitPoint(x: 0.15, y: 0.05), startRadius: 0, endRadius: 200))
                            .overlay(Color.white.opacity(0.03))
                    }
                }
                .overlay(
                    Capsule()
                        .strokeBorder(Color.white.opacity(configuration.isPressed ? 0.38 : 0.30), lineWidth: 1)
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
        apply(GlassTheme.style)
    }

    /// 按玻璃质感档位刷新导航/标签栏（切换质感时实时生效）
    static func apply(_ style: GlassStyle) {
        let blur: UIBlurEffect.Style
        let tabAlpha: CGFloat
        let navAlpha: CGFloat
        switch style {
        case .thin:
            blur = .systemUltraThinMaterial; tabAlpha = 0.08; navAlpha = 0.06
        case .frost:
            blur = .systemMaterial; tabAlpha = 0.30; navAlpha = 0.26
        case .smoke:
            blur = .systemMaterialDark; tabAlpha = 0.28; navAlpha = 0.24
        case .crystal:
            blur = .systemUltraThinMaterial; tabAlpha = 0.04; navAlpha = 0.03
        case .amber:
            blur = .systemUltraThinMaterial; tabAlpha = 0.12; navAlpha = 0.10
        case .obsidian:
            blur = .systemMaterialDark; tabAlpha = 0.40; navAlpha = 0.35
        case .aurora:
            blur = .systemUltraThinMaterial; tabAlpha = 0.14; navAlpha = 0.12
        }

        let tab = UITabBarAppearance()
        tab.configureWithTransparentBackground()
        tab.backgroundEffect = UIBlurEffect(style: blur)
        tab.backgroundColor = UIColor.systemBackground.withAlphaComponent(tabAlpha)
        tab.shadowColor = .clear
        tab.shadowImage = UIImage()
        UITabBar.appearance().standardAppearance = tab
        UITabBar.appearance().scrollEdgeAppearance = tab

        let nav = UINavigationBarAppearance()
        nav.configureWithTransparentBackground()
        nav.backgroundEffect = UIBlurEffect(style: blur)
        nav.backgroundColor = UIColor.systemBackground.withAlphaComponent(navAlpha)
        nav.shadowColor = .clear
        nav.shadowImage = UIImage()
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav
        UINavigationBar.appearance().compactAppearance = nav
    }
}
