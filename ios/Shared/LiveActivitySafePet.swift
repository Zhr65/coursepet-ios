// MARK: - Live Activity 专用极简宠物视图（扩展渲染环境安全版）
// 只渲染静态帧：按需缩略解码（上限 160px），用完释放——WidgetKit 扩展只有 30~50MB。
// 不用 Timer / withAnimation 做循环动画：Live Activity 靠系统快照渲染，帧循环不会推进，
// 快照还会把 repeatForever 的瞬间值定格成歪姿态。
// 岛上要"自己动"只有一条路：SwingAnimation —— 底层是 clockHandRotationEffect 私有 API
// （系统时钟秒针用的那个），只有 WidgetKit 渲染环境认，主 App 里加了也不会动。
//
// 动法按素材自动挑：
//   ① 该动作有真多帧（pet_walk_1.png 之类存在）→ 帧传送带：N 张图竖排成一条带子，
//      外面只留一格窗口，整条带子上下平移，窗口里就一帧帧轮流过 —— char1~9 能迈腿；
//   ② 只有一张静态图（char10~15）→ 退回静态帧上下轻晃。
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
        if swing, animationFrames.count >= 3 {
            conveyor
        } else if swing {
            // 单帧：上下轻晃，幅度跟着尺寸走（岛屿区域窄，晃太大会撞到旁边的文案）
            petImage.swingAnimation(duration: 2.0, direction: .vertical, distance: size * 0.15)
        } else {
            petImage
        }
        #else
        petImage
        #endif
    }

    /// 要播的动作与帧数：优先当前动作，该动作没有帧图就退回 idle（char10~15 只有 idle_0）
    private var animationFrames: (action: String, count: Int) {
        let n = PetFrameLocator.frameCount(action: action, charId: charId)
        if n >= 2 { return (action, n) }
        return ("idle", PetFrameLocator.frameCount(action: "idle", charId: charId))
    }

    // MARK: - 帧传送带
    /// 竖排 N 张帧图 → 窗口只露一格 → 整条带子靠 swingAnimation 上下平移，窗口里逐帧过。
    /// 末尾补一张首帧：窗口居中要能扫到最后一帧，补完首尾还天然衔接成循环。
    /// 往返式播放（正弦来回）对"迈腿"这类循环动作肉眼看不出倒放，换来了零额外私有 API 依赖。
    @ViewBuilder
    private var conveyor: some View {
        #if canImport(SwingAnimation)
        let spec = animationFrames
        let images = (0..<spec.count).compactMap {
            Self.loadDownsampled(action: spec.action, charId: charId, frame: $0)
        }
        if images.count >= 3 {
            let strip = images + [images[0]]
            let stripCount = CGFloat(strip.count)
            // 带子居中时窗口正对中间那帧；要让窗口扫到首帧/末帧各一次，
            // 单边行程 = (带子帧数 - 1) / 2 格（此时窗口边缘正好压住带子两端，不会露白）
            let travel = size * (stripCount - 1) / 2

            VStack(spacing: 0) {
                ForEach(Array(strip.enumerated()), id: \.offset) { _, img in
                    Image(uiImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: size, height: size)
                }
            }
            .frame(width: size, height: size * stripCount, alignment: .top)
            // 一个正弦周期里窗口来回扫 4 遍行程、共过 2 × 带子格数 帧，
            // 取 0.2s/帧 → 周期 ≈ 帧数 × 0.4（char1~9 是 8 帧 → 一圈 1.6s，像慢走）
            .swingAnimation(duration: Double(spec.count) * 0.4,
                            direction: .vertical,
                            distance: travel)
            .frame(width: size, height: size)   // 布局占位只有一格，带子居中 → 露正中间那一帧
            .clipped()
        } else {
            // 解码失败（帧文件缺失）：退回单帧轻晃，别让岛上空白
            petImage.swingAnimation(duration: 2.0, direction: .vertical, distance: size * 0.15)
        }
        #else
        petImage
        #endif
    }

    /// 宠物本体（静态帧）
    @ViewBuilder
    private var petImage: some View {
        Group {
            if let img = Self.loadDownsampled(action: action, charId: charId, frame: 0) {
                Image(uiImage: img).resizable().aspectRatio(contentMode: .fit)
            } else {
                Text("🐾").font(.system(size: size * 0.8))
            }
        }
        .frame(width: size, height: size)
    }

    // MARK: - 按需缩略解码（核心：只解一帧，解码结果进 NSCache——聊天头像每次渲染
    // 都走这里，不缓存的话每条消息都重新读盘+解码；NSCache 内存吃紧自动逐出，扩展里也安全）
    private static let frameCache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 96
        return c
    }()

    private static func loadDownsampled(action: String, charId: String, frame: Int) -> UIImage? {
        let key = "\(action)|\(charId)|\(frame)" as NSString
        if let hit = frameCache.object(forKey: key) { return hit }

        // 帧图定位交给 PetFrameLocator：含"新形象只有一张静态图"的动作 / 帧回落
        guard let fileURL = PetFrameLocator.url(action: action, charId: charId, frame: frame),
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
        let img = UIImage(cgImage: cgImage)
        frameCache.setObject(img, forKey: key)
        return img
    }
}