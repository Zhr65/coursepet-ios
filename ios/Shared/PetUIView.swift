// MARK: - SwiftUI 共享工具（供主 App、Widget、Live Activity 扩展共用）
// 这些类型在 Shared target 中定义为 public，确保所有扩展都能访问

import SwiftUI

// MARK: - 颜色工具
extension Color {
    /// 从十六进制字符串初始化（如 "#FFD1C4" 或 "FFD1C4"）
    init?(hex: String) {
        var h = hex.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: "")
        guard h.count == 6 else { return nil }
        var rgb: UInt64 = 0
        Scanner(string: h).scanHexInt64(&rgb)
        self.init(
            red: Double((rgb >> 16) & 0xFF) / 255.0,
            green: Double((rgb >> 8) & 0xFF) / 255.0,
            blue: Double(rgb & 0xFF) / 255.0
        )
    }
}

// MARK: - 宠物帧动画播放器
/// 从 App Group 容器动态加载 pet_{action}_{frame}.png 帧图片
/// 公开给主 App、Widget 和 Live Activity 扩展使用
struct PetAnimationView: View {
    let action: String
    let charId: String
    let speed: AppSettings.AnimSpeed
    let size: CGFloat
    let loop: Bool
    let liveActivityMode: Bool   // 灵动岛模式：10秒后暂停

    private let frameCount = 8
    private var frameInterval: TimeInterval {
        switch speed {
        case .slow: return 0.45
        case .mid:  return 0.20
        case .fast: return 0.10
        }
    }

    @State private var currentFrame: Int = 0
    @State private var timer: Timer?
    /// 是否存在 PNG 帧：nil=尚未检查，false=真机上没有帧图（走程序化宠物兜底）
    @State private var hasPngFrames: Bool?

    init(
        action: String,
        charId: String = "char1",
        speed: AppSettings.AnimSpeed = .mid,
        size: CGFloat = 120,
        loop: Bool = true,
        liveActivityMode: Bool = false
    ) {
        self.action = action
        self.charId = charId
        self.speed = speed
        self.size = size
        self.loop = loop
        self.liveActivityMode = liveActivityMode
    }

    var body: some View {
        Group {
            switch hasPngFrames {
            case .some(true):
                // 有帧图：走原有 PNG 帧动画
                AsyncImage(url: frameURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: size, height: size)
                            .transition(.opacity)
                    case .failure:
                        // 单帧加载失败也兜底为程序化宠物，避免卡 loading
                        ProceduralPetView(action: action, charId: charId, speed: speed, size: size)
                            .id("\(action)-\(charId)-\(speed)")
                    case .empty:
                        Color.clear.frame(width: size, height: size)
                    @unknown default:
                        EmptyView()
                    }
                }
            case .some(false):
                // 一张 PNG 都没有：渲染内置程序化宠物
                ProceduralPetView(action: action, charId: charId, speed: speed, size: size)
                    .id("\(action)-\(charId)-\(speed)")
            case .none:
                // 尚未检查完：透明占位，避免闪现 loading
                Color.clear.frame(width: size, height: size)
            }
        }
        .onAppear {
            checkPngFrames()
        }
        .onDisappear { stopAnimation() }
    }

    // MARK: - 帧图片 URL（App Group 容器）
    private func frameURL(at index: Int) -> URL? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.coursepet.app"
        ) else { return nil }
        let fileName = "pet_\(action)_\(index).png"
        return container
            .appendingPathComponent("Documents")
            .appendingPathComponent("PetAnimations")
            .appendingPathComponent(charId)
            .appendingPathComponent(fileName)
    }

    private var frameURL: URL? { frameURL(at: currentFrame) }

    /// 同步检查第 0 帧是否存在（本地文件检查很快，不会卡界面）
    private func checkPngFrames() {
        let exists: Bool
        if let url = frameURL(at: 0), FileManager.default.fileExists(atPath: url.path) {
            exists = true
        } else {
            exists = false
        }
        hasPngFrames = exists
        if exists {
            startAnimation()
        } else {
            stopAnimation()
        }
    }

    // MARK: - 动画控制
    private func startAnimation() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: frameInterval, repeats: true) { _ in
            if self.liveActivityMode {
                // 灵动岛模式：10秒后自动暂停
                self.advanceFrame()
            } else {
                withAnimation {
                    self.currentFrame = (self.currentFrame + 1) % self.frameCount
                }
            }
        }
    }

    private func advanceFrame() {
        currentFrame += 1
        if currentFrame >= frameCount {
            stopAnimation()
            currentFrame = 0
            if loop { startAnimation() }
        }
    }

    private func stopAnimation() {
        timer?.invalidate()
        timer = nil
    }
}

// MARK: - 程序化宠物（真机没有 PNG 帧时的内置兜底形象：圆形团子）
/// 用 SwiftUI shape 绘制：径向渐变身体 + 顶部造型 + 表情，
/// charId 决定配色与造型（char1 橙色火苗 / char2 蓝色水滴 / char3 绿色芽苗），
/// speed 决定浮动/跳动等环境动画快慢（慢/中/快三档真实生效），
/// 表情与动画随 action 变化（idle 浮动 / happy 跳动 / sleep·sleepy 眯眼呼吸 / nervous 抖动）
struct ProceduralPetView: View {
    let action: String
    var charId: String = "char1"
    var speed: AppSettings.AnimSpeed = .mid
    let size: CGFloat

    // 顶部造型风格
    private enum TipStyle {
        case flame    // 火苗尖（char1）
        case drop     // 水滴尖（char2）
        case sprout   // 双叶芽苗（char3）
    }

    // 环境动画状态（onAppear 时按 action 启动对应动画）
    @State private var floatUp = false      // 上下浮动
    @State private var bouncing = false     // 跳动
    @State private var breathing = false    // 呼吸
    @State private var wiggling = false     // 紧张抖动

    var body: some View {
        ZStack {
            // 地面光晕
            Ellipse()
                .fill(palette.glow.opacity(0.18))
                .frame(width: size * 0.78, height: size * 0.16)
                .offset(y: size * 0.42)

            VStack(spacing: -size * 0.05) {
                // 顶部造型（按 charId 切换，fill 必须加在每个 Shape 上，Group 不支持）
                Group {
                    switch palette.tip {
                    case .sprout:
                        SproutTip()
                            .fill(bodyGradient)
                    default:
                        // 火苗尖与水滴共用同一轮廓，靠配色区分风格
                        FlameTip()
                            .fill(bodyGradient)
                    }
                }
                .frame(width: size * 0.30, height: size * 0.34)
                // 身体（径向渐变圆团子）
                Circle()
                    .fill(bodyGradient)
                    .frame(width: size * 0.68, height: size * 0.68)
                    .overlay(face)
            }

            // 睡觉时的 Zzz
            if action == "sleep" || action == "sleepy" {
                Text("z Z")
                    .font(.system(size: size * 0.14, weight: .bold))
                    .foregroundColor(palette.glow.opacity(0.85))
                    .offset(x: size * 0.30, y: -size * 0.34)
            }
        }
        .frame(width: size, height: size)
        .scaleEffect(breathing ? 1.04 : 1.0)
        .rotationEffect(.degrees(wiggling ? 2.5 : -2.5))
        .offset(y: bouncing ? -size * 0.05 : 0)
        .offset(y: floatUp ? -size * 0.025 : size * 0.025)
        .onAppear { startAmbientAnimation() }
    }

    // MARK: - 形象配色（charId 三套：1 火苗 / 2 水滴 / 3 芽苗）
    private struct Palette {
        let body: [Color]   // 径向渐变三层色（中心 → 边缘）
        let glow: Color     // 光晕 / Zzz 用主色
        let tip: TipStyle
    }

    private var palette: Palette {
        switch charId {
        case "char2":
            // 蓝色水滴风
            return Palette(
                body: [
                    Color(red: 0.88, green: 0.97, blue: 1.00),   // 中心浅蓝白
                    Color(red: 0.49, green: 0.83, blue: 0.99),   // 中层天蓝
                    Color(red: 0.20, green: 0.66, blue: 0.94)    // 边缘深蓝
                ],
                glow: Color(red: 0.20, green: 0.66, blue: 0.94),
                tip: .drop
            )
        case "char3":
            // 绿色芽苗风
            return Palette(
                body: [
                    Color(red: 0.93, green: 0.99, blue: 0.80),   // 中心嫩黄绿
                    Color(red: 0.53, green: 0.90, blue: 0.66),   // 中层草绿
                    Color(red: 0.20, green: 0.78, blue: 0.48)    // 边缘深绿
                ],
                glow: Color(red: 0.20, green: 0.78, blue: 0.48),
                tip: .sprout
            )
        default:
            // char1：橙色火苗（原配色）
            return Palette(
                body: [
                    Color(red: 1.00, green: 0.93, blue: 0.55),   // 中心亮黄
                    Color(red: 1.00, green: 0.64, blue: 0.26),   // 中层橙
                    Color(red: 0.97, green: 0.45, blue: 0.16)    // 边缘深橙
                ],
                glow: Color.orange,
                tip: .flame
            )
        }
    }

    // MARK: - 身体渐变
    private var bodyGradient: RadialGradient {
        RadialGradient(
            gradient: Gradient(colors: palette.body),
            center: .center,
            startRadius: size * 0.02,
            endRadius: size * 0.38
        )
    }

    // MARK: - 动画速度倍率（慢→1.8 倍时长 / 快→0.5 倍时长）
    private var speedFactor: Double {
        switch speed {
        case .slow: return 1.8
        case .mid:  return 1.0
        case .fast: return 0.5
        }
    }

    // MARK: - 表情（随 action 变化）
    private var face: some View {
        VStack(spacing: size * 0.05) {
            eyes
            mouth
        }
        .offset(y: -size * 0.02)
    }

    @ViewBuilder
    private var eyes: some View {
        let eyeSize = size * 0.09
        switch action {
        case "sleep", "sleepy":
            // 眯眼：两条短横线
            HStack(spacing: size * 0.13) {
                Capsule().fill(eyeColor).frame(width: eyeSize * 1.2, height: eyeSize * 0.28)
                Capsule().fill(eyeColor).frame(width: eyeSize * 1.2, height: eyeSize * 0.28)
            }
        case "happy", "excite", "walk":
            // 开心弯眼：上凸弧线（∩ 形）
            HStack(spacing: size * 0.11) {
                arcEye
                arcEye
            }
        case "nervous", "weak":
            // 无精打采/紧张：小圆眼
            HStack(spacing: size * 0.13) {
                Circle().fill(eyeColor).frame(width: eyeSize * 0.75, height: eyeSize * 0.75)
                Circle().fill(eyeColor).frame(width: eyeSize * 0.75, height: eyeSize * 0.75)
            }
        default:
            // 默认圆眼 + 高光
            HStack(spacing: size * 0.12) {
                roundEye(eyeSize)
                roundEye(eyeSize)
            }
        }
    }

    private var eyeColor: Color {
        // 深棕色调在三套浅色渐变身体上都有足够对比度
        Color(red: 0.28, green: 0.13, blue: 0.04)
    }

    private func roundEye(_ eyeSize: CGFloat) -> some View {
        ZStack {
            Circle().fill(eyeColor).frame(width: eyeSize, height: eyeSize)
            Circle().fill(Color.white).frame(width: eyeSize * 0.38, height: eyeSize * 0.38)
                .offset(x: -eyeSize * 0.18, y: -eyeSize * 0.18)
        }
    }

    // 上凸弧线眼睛（开心眯眼）
    private var arcEye: some View {
        let s = size * 0.11
        return Circle()
            .trim(from: 0.5, to: 1.0)
            .stroke(eyeColor, style: StrokeStyle(lineWidth: size * 0.028, lineCap: .round))
            .frame(width: s, height: s)
    }

    @ViewBuilder
    private var mouth: some View {
        switch action {
        case "happy", "excite", "walk":
            // 微笑：下凸弧线（∪ 形）
            Circle()
                .trim(from: 0.0, to: 0.5)
                .stroke(eyeColor, style: StrokeStyle(lineWidth: size * 0.026, lineCap: .round))
                .frame(width: size * 0.14, height: size * 0.10)
        case "nervous":
            // 紧张小圆嘴
            Circle()
                .fill(eyeColor)
                .frame(width: size * 0.05, height: size * 0.05)
        case "sleep", "sleepy":
            EmptyView()
        default:
            // 平静短横嘴
            Capsule()
                .fill(eyeColor)
                .frame(width: size * 0.09, height: size * 0.022)
        }
    }

    // MARK: - 环境动画（按 action 启动，时长乘以速度倍率）
    private func startAmbientAnimation() {
        let f = speedFactor
        switch action {
        case "happy", "excite", "walk":
            // 跳动
            withAnimation(.easeInOut(duration: 0.38 * f).repeatForever(autoreverses: true)) {
                bouncing = true
            }
        case "sleep", "sleepy":
            // 缓慢呼吸
            withAnimation(.easeInOut(duration: 1.8 * f).repeatForever(autoreverses: true)) {
                breathing = true
            }
        case "nervous":
            // 左右发抖
            withAnimation(.linear(duration: 0.12 * f).repeatForever(autoreverses: true)) {
                wiggling = true
            }
        default:
            // idle 等动作：轻微上下浮动
            withAnimation(.easeInOut(duration: 1.6 * f).repeatForever(autoreverses: true)) {
                floatUp = true
            }
        }
    }
}

// 火苗尖形状：底部宽、顶部收尖的水滴形
private struct FlameTip: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addQuadCurve(
            to: CGPoint(x: rect.maxX * 0.90, y: rect.maxY),
            control: CGPoint(x: rect.maxX + rect.width * 0.10, y: rect.midY)
        )
        p.addLine(to: CGPoint(x: rect.minX + rect.width * 0.10, y: rect.maxY))
        p.addQuadCurve(
            to: CGPoint(x: rect.midX, y: rect.minY),
            control: CGPoint(x: rect.minX - rect.width * 0.10, y: rect.midY)
        )
        p.closeSubpath()
        return p
    }
}

// 芽苗尖形状：两片对生小叶（char3 顶部造型）
private struct SproutTip: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        // 左叶：从底部中心向左上弯出再收回
        p.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        p.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.midY * 0.5),
            control: CGPoint(x: rect.minX, y: rect.maxY)
        )
        p.addQuadCurve(
            to: CGPoint(x: rect.midX, y: rect.maxY),
            control: CGPoint(x: rect.minX + rect.width * 0.15, y: rect.maxY * 0.40)
        )
        // 右叶：镜像对称
        p.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        p.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.midY * 0.5),
            control: CGPoint(x: rect.maxX, y: rect.maxY)
        )
        p.addQuadCurve(
            to: CGPoint(x: rect.midX, y: rect.maxY),
            control: CGPoint(x: rect.maxX - rect.width * 0.15, y: rect.maxY * 0.40)
        )
        p.closeSubpath()
        return p
    }
}

// MARK: - 宠物气泡文字视图
struct PetBubble: View {
    let text: String
    let isVisible: Bool

    init(text: String, isVisible: Bool = true) {
        self.text = text
        self.isVisible = isVisible
    }

    var body: some View {
        Group {
            if isVisible && !text.isEmpty {
                ZStack {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color(.systemBackground))
                        .shadow(color: .black.opacity(0.1), radius: 3, y: 2)
                    Text(text)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.primary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                }
                .overlay(
                    TriangleShape()
                        .fill(Color(.systemBackground))
                        .offset(y: 8),
                    alignment: .bottom
                )
            }
        }
    }
}

private struct TriangleShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX - 8, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.midX + 8, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY - 10))
        p.closeSubpath()
        return p
    }
}
