// MARK: - Live Activity 专用极简宠物视图（扩展渲染环境安全版）
// 只渲染一帧静态图：按需缩略解码（上限 160px），用完释放——WidgetKit 扩展只有 30~50MB。
// 不用 Timer / withAnimation 做循环动画：Live Activity 靠系统快照渲染，帧循环不会推进，
// 快照还会把 repeatForever 的瞬间值定格成歪姿态。
// 岛/锁屏上要"持续动"走 SwingAnimation —— 底层是 clockHandRotationEffect 私有 API
// （系统时钟秒针用的那个），只有 WidgetKit 渲染环境认，主 App 里加了也不会动。
import SwiftUI
import ImageIO
#if canImport(SwingAnimation)
import SwingAnimation
#endif

struct LiveActivitySafePet: View {
    let action: String
    let charId: String
    let size: CGFloat
    /// 持续摆动开关：只在灵动岛 / 锁屏开。主 App 的聊天头像不开，避免跟着一起晃。
    var swing: Bool = false

    var body: some View {
        #if canImport(SwingAnimation)
        if swing {
            // 上下轻晃，幅度跟着尺寸走（岛屿区域窄，晃太大会撞到旁边的文案）
            petImage.swingAnimation(duration: 2.0, direction: .vertical, distance: size * 0.15)
        } else {
            petImage
        }
        #else
        petImage
        #endif
    }

    /// 宠物本体（静态帧）
    @ViewBuilder
    private var petImage: some View {
        Group {
            if let img = Self.loadDownsampled(action: action, charId: charId) {
                Image(uiImage: img).resizable().aspectRatio(contentMode: .fit)
            } else {
                Text("🐾").font(.system(size: size * 0.8))
            }
        }
        .frame(width: size, height: size)
    }

    // MARK: - 按需缩略解码（核心：只解一帧，用完释放）
    private static func loadDownsampled(action: String, charId: String) -> UIImage? {
        // 帧图定位交给 PetFrameLocator：含"新形象只有一张静态图"的动作 / 帧回落
        guard let fileURL = PetFrameLocator.url(action: action, charId: charId, frame: 0),
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