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
        AsyncImage(url: frameURL) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size, height: size)
                    .transition(.opacity)
            case .failure:
                placeholderView
            case .empty:
                ProgressView()
                    .frame(width: size, height: size)
            @unknown default:
                EmptyView()
            }
        }
        .onAppear { startAnimation() }
        .onDisappear { stopAnimation() }
    }

    // MARK: - 帧图片 URL（App Group 容器）
    private var frameURL: URL? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.coursepet.app"
        ) else { return nil }
        let fileName = "pet_\(action)_\(currentFrame).png"
        return container
            .appendingPathComponent("Documents")
            .appendingPathComponent("PetAnimations")
            .appendingPathComponent(charId)
            .appendingPathComponent(fileName)
    }

    private var placeholderView: some View {
        ZStack {
            Circle()
                .fill(Color.orange.opacity(0.2))
                .frame(width: size, height: size)
            Text(petEmoji)
                .font(.system(size: size * 0.5))
        }
        .frame(width: size, height: size)
    }

    private var petEmoji: String {
        switch action {
        case "idle":      return "🐾"
        case "walk":      return "🚶"
        case "happy":     return "😄"
        case "excite":    return "🤩"
        case "nervous":   return "😰"
        case "sleep":     return "😴"
        case "listen":    return "🎧"
        case "charge":    return "⚡"
        case "weak":      return "😷"
        default:          return "🐾"
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
