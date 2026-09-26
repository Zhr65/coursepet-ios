// MARK: - Live Activity 专用极简宠物视图（扩展渲染环境安全版）
// 背景：WidgetKit / 灵动岛扩展的渲染进程内存上限极低（约 30~50MB），
// PetAnimationView 的多帧 UIImage 同步加载 + Timer + withAnimation 在该环境
// 会导致渲染失败——表现为 Activity 创建成功但灵动岛/锁屏横幅整块空白。
// 此组件：单帧 + ImageIO 低内存缩略解码 + 零动画零副作用，保证可渲染。
import SwiftUI
import ImageIO

struct LiveActivitySafePet: View {
    let action: String
    let charId: String
    let size: CGFloat

    var body: some View {
        if let image = Self.loadDownsampled(action: action, charId: charId) {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        } else {
            // 无帧图：显示爪印（用户要求灵动岛绝不显示程序化团子兜底）
            Text("🐾")
                .font(.system(size: size * 0.8))
                .frame(width: size, height: size)
        }
    }

    /// 低内存解码第 0 帧：App Group 容器优先，Bundle 内置兜底
    private static func loadDownsampled(action: String, charId: String) -> UIImage? {
        var url: URL?
        // 1) App Group 容器（正常签名环境的主数据源）
        if let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.coursepet.app"
        ) {
            let candidate = container
                .appendingPathComponent("Documents")
                .appendingPathComponent("PetAnimations")
                .appendingPathComponent(charId)
                .appendingPathComponent("pet_\(action)_0.png")
            if FileManager.default.fileExists(atPath: candidate.path) {
                url = candidate
            }
        }
        // 2) 自身 Bundle 内置（folder reference 保持 AppPetAssets/charX/ 结构，
        //    免费签名等 App Group 不可用环境下扩展也能显示真形象）
        if url == nil {
            url = Bundle.main.url(
                forResource: "pet_\(action)_0",
                withExtension: "png",
                subdirectory: "AppPetAssets/\(charId)"
            )
        }
        guard let fileURL = url,
              let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil)
        else { return nil }

        // 缩略解码：先按最大 160px 生成缩略图再解压，避免大图（1024~2048px）
        // 直接解压成 4~16MB 位图撑爆扩展渲染进程
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
