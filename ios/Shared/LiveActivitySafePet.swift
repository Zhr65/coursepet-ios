// MARK: - Live Activity 专用极简宠物视图（扩展渲染环境安全版）
// 华强北耳机灵动岛方案：帧序列循环切图（Timer 每 ~120ms 推一帧）+ 2D 修饰伪 3D。
// 每帧按需缩略解码（内存上限 160px），用完释放——WidgetKit 扩展只有 30~50MB。
// 不预加载全部帧、不用 withAnimation 包帧切换（会触发扩展渲染循环警告）。
// 呼吸/浮动/踱步转身用 scaleEffect/offset（最安全的两种 SwiftUI 修饰）。
import SwiftUI
import ImageIO
import Combine

struct LiveActivitySafePet: View {
    let action: String
    let charId: String
    let size: CGFloat
    /// 静帧开关：false = 只显示第 0 帧 + 无动画（聊天页顶部小图场景）
    var animated: Bool = true

    // MARK: - 帧循环状态（仅 animated=true 时驱动）
    @State private var frameIndex: Int = 0           // 当前帧索引 0...7
    private let frameCount = 8                       // pet_<action>_0.png ~ 7.png

    // MARK: - 伪 3D 环境动画（呼吸 + 浮动 + 踱步转身）
    @State private var breathing = false
    @State private var floatY = false
    @State private var walkPhase = false

    var body: some View {
        Group {
            if animated {
                animatedPet
            } else {
                staticPet
            }
        }
        .frame(width: size, height: size)
    }

    // MARK: - 静帧（只加载 frame 0）
    @ViewBuilder
    private var staticPet: some View {
        if let img = Self.loadDownsampled(action: action, charId: charId, frame: 0) {
            Image(uiImage: img).resizable().aspectRatio(contentMode: .fit)
        } else {
            Text("🐾").font(.system(size: size * 0.8))
        }
    }

    // MARK: - 动画帧（Timer 循环切图 + 伪 3D 修饰）
    @ViewBuilder
    private var animatedPet: some View {
        Group {
            // 用 frameIndex 作为 id，SwiftUI 会在帧变化时重建视图 → 触发新缩略解码
            if let img = Self.loadDownsampled(action: action, charId: charId, frame: frameIndex) {
                Image(uiImage: img).resizable().aspectRatio(contentMode: .fit)
                    .id("pet-\(frameIndex)")
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            } else {
                Text("🐾").font(.system(size: size * 0.8))
            }
        }
        .animation(.easeOut(duration: 0.12), value: frameIndex)
        // 伪 3D 修饰（转身 + 呼吸 + 浮动）
        .scaleEffect(x: walkPhase ? -1 : 1, y: 1)
        .offset(x: walkPhase ? size * 0.15 : -size * 0.15)
        .scaleEffect(breathing ? 1.045 : 1.0)
        .offset(y: floatY ? -size * 0.05 : 0)
        .onAppear { startAnimations() }
        // 离开渲染树时停止 Timer（WidgetKit 扩展会复用 View 实例，onDisappear 是安全钩子）
        .onDisappear { stopAnimations() }
    }

    // MARK: - 启动/停止
    private func startAnimations() {
        // 帧循环：~120ms/帧 → 8 帧 ≈ 0.96 秒一圈（华强北耳机约 100ms）
        // 8 帧循环 0→7→0：Timer.publish 每 tick 推进一帧
        frameTimer = Timer.publish(every: 0.12, on: .main, in: .common)
            .autoconnect()
            .sink { _ in
                frameIndex = (frameIndex + 1) % frameCount
            }

        // 伪 3D：呼吸 + 浮动 + 踱步转身
        withAnimation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true)) {
            breathing = true
        }
        withAnimation(.easeInOut(duration: 1.7).repeatForever(autoreverses: true)) {
            floatY = true
        }
        withAnimation(.easeInOut(duration: 2.8).repeatForever(autoreverses: true)) {
            walkPhase = true
        }
    }

    private func stopAnimations() {
        frameTimer?.cancel()
        frameTimer = nil
    }

    /// Timer 句柄，onDisappear 时 cancel 防泄漏
    @State private var frameTimer: Cancellable?

    // MARK: - 按需缩略解码（核心：每次只解一帧，用完释放）
    private static func loadDownsampled(action: String, charId: String, frame: Int) -> UIImage? {
        var url: URL?
        // 1) App Group 容器（正常签名环境的主数据源）
        if let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.coursepet.app"
        ) {
            let candidate = container
                .appendingPathComponent("Documents")
                .appendingPathComponent("PetAnimations")
                .appendingPathComponent(charId)
                .appendingPathComponent("pet_\(action)_\(frame).png")
            if FileManager.default.fileExists(atPath: candidate.path) {
                url = candidate
            }
        }
        // 2) Bundle 内置兜底（免费签名等 App Group 不可用环境下扩展也能显示真形象）
        if url == nil {
            url = Bundle.main.url(
                forResource: "pet_\(action)_\(frame)",
                withExtension: "png",
                subdirectory: "AppPetAssets/\(charId)"
            )
        }
        guard let fileURL = url,
              let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil)
        else { return nil }

        // 缩略解码：按最大 160px 生成缩略图再解压，避免大图直接解压撑爆扩展渲染进程
        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: 160
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }
}
