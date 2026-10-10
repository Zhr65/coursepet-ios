// MARK: - 主 App 专用：真 3D 宠物（SceneKit 实时渲染 + 手动拖转）
// 有 .usdz / .obj 模型就上真 3D；没有就原样回落 Shared/PetUIView.swift 里的平面帧动画
// PetAnimationView，所以没放模型时界面跟以前完全一样。
// 交互设计：平时静立不动，手指在宠物身上横扫才转（拖多远转多少，松手停住）；
// 竖向拖动不拦，留给外层页面滚动。
// 本文件只编进主 App target，不进 Widget / Live Activity 扩展：
//   ① SceneKit 在扩展里白占 30~50MB 内存上限；
//   ② 灵动岛/锁屏是系统快照渲染，连续动画根本不触发重绘（结论已验证）。
// 部署目标 iOS 16.1 → 用 SceneKit，不用 RealityKit（RealityView 需 iOS 17+）。
import SwiftUI
import SceneKit
import UIKit

// MARK: - 3D 模型定位
enum Pet3DModelLocator {
    /// 认的模型扩展名，按顺序试。
    /// usdz/usd/usdc 是 SceneKit 原生就能读的；
    /// obj 走底下的 Model I/O（MDLAsset）也能读，所以腾讯云混元生3D 只给 OBJ/GLB 时，
    /// 直接下 OBJ（连同 .mtl 和贴图放同一个目录）就能用，不用转格式。
    /// GLB 两种都不认，别下。
    private static let modelExtensions = ["usdz", "usd", "usdc", "obj"]

    /// 解析结果缓存（charId → URL/nil）：PetModelView.body 每次求值都调 hasModel/url，
    /// 不缓存的话最多 12 次磁盘检查 × 每帧渲染。nil 也缓存（=已确认无模型）。
    /// 代价：往 Pet3D 目录手动放新模型需重启 App 生效（可接受）。
    private static var resolvedCache: [String: URL?] = [:]

    /// 该形象有没有 3D 模型；nil 表示还没做，走平面图（结果缓存）
    static func url(charId: String) -> URL? {
        if let cached = resolvedCache[charId] { return cached }
        let resolved = resolve(charId: charId)
        resolvedCache[charId] = resolved
        return resolved
    }

    private static func resolve(charId: String) -> URL? {
        // 1) 沙盒 Documents/Pet3D/{charId}.xxx
        //    Info.plist 已开 UIFileSharingEnabled，可以直接从
        //    「文件」App → 我的 iPhone → CoursePet → Pet3D 里投放，不用重新构建
        if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            for ext in modelExtensions {
                let u = docs.appendingPathComponent("Pet3D/\(charId).\(ext)")
                if FileManager.default.fileExists(atPath: u.path) { return u }
            }
        }
        // 2) AppPetAssets/{charId}/{charId}.xxx——模型随包发布走这条
        //    AppPetAssets 在 project.yml 里是 folder reference，整个目录原样拷进
        //    Bundle，所以跟帧图放一起就能自动带上，不用再改 project.yml
        for ext in modelExtensions {
            if let u = Bundle.main.url(forResource: charId, withExtension: ext,
                                       subdirectory: "AppPetAssets/\(charId)") { return u }
        }
        // 3) Bundle 根目录——给手动拖进 Xcode 的模型留个口子
        for ext in modelExtensions {
            if let u = Bundle.main.url(forResource: charId, withExtension: ext) { return u }
        }
        return nil
    }

    static func hasModel(charId: String) -> Bool { url(charId: charId) != nil }

    /// 启动时建好 Documents/Pet3D/ 空目录：
    /// UIFileSharingEnabled 只暴露已存在的目录，「文件」App 里得先有文件夹才能往里放模型
    static func prepareImportFolder() {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        try? FileManager.default.createDirectory(
            at: docs.appendingPathComponent("Pet3D", isDirectory: true),
            withIntermediateDirectories: true
        )
    }
}

// MARK: - SceneKit 渲染视图（UIViewRepresentable 包一层 SCNView）
struct SceneKitPetView: UIViewRepresentable {
    let charId: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// 拖转手势状态：记录上一次手指 x，增量旋转模型容器节点
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        weak var modelNode: SCNNode?
        /// 视图已被销毁标记：异步加载完成时视图可能已随页面关闭，装配前检查防复用错乱
        var tornDown = false
        private var lastX: CGFloat?

        @objc func handlePan(_ g: UIPanGestureRecognizer) {
            switch g.state {
            case .changed:
                let x = g.translation(in: g.view).x
                if let last = lastX {
                    // 灵敏度跟视图宽度挂钩：扫过一只宠物的宽度 ≈ 转半圈
                    // bounds.width 是 CGFloat，先转成 Float 再算，避免 Float/CGFloat 混算编译错
                    let width = Float(g.view?.bounds.width ?? 150)
                    let factor = Float.pi / max(width, 60)
                    // 往左滑 = 逆时针、往右滑 = 顺时针（正面视角，用户实测定的方向）
                    modelNode?.eulerAngles.y += Float(x - last) * factor
                }
                lastX = x
            default:
                lastX = nil
            }
        }

        /// 点一下：蹲→跳起→落地→左右扭两下，当打招呼（静态网格模型做不了真挥手）
        @objc func handleTap() {
            guard let node = modelNode, node.action(forKey: "petBounce") == nil else { return }
            // 腾讯模型顶点归一在 0~1，位移/扭角按模型自身比例给；净量都为 0，动画完回正
            let bounce = SCNAction.sequence([
                SCNAction.scale(to: 0.94, duration: 0.1),                                // 蹲
                SCNAction.group([SCNAction.moveBy(x: 0, y: 0.07, z: 0, duration: 0.14),  // 跳起
                                 SCNAction.scale(to: 1.05, duration: 0.14)]),
                SCNAction.group([SCNAction.moveBy(x: 0, y: -0.07, z: 0, duration: 0.16), // 落地
                                 SCNAction.scale(to: 1.0, duration: 0.16)]),
                SCNAction.rotateBy(x: 0, y: 0, z: 0.14, duration: 0.1),                  // 右扭
                SCNAction.rotateBy(x: 0, y: 0, z: -0.28, duration: 0.18),                // 左扭
                SCNAction.rotateBy(x: 0, y: 0, z: 0.14, duration: 0.1),                  // 回正
            ])
            node.runAction(bounce, forKey: "petBounce")
        }

        // 与外层 ScrollView 的滚动手势并存：竖向拖动页面照常滚，这里只吃横向分量
        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = .clear
        view.antialiasingMode = .multisampling4X
        view.autoenablesDefaultLighting = true   // 自动打光：AI 出的模型材质吃这套就够
        view.preferredFramesPerSecond = 30

        // 手势先挂上（模型还没加载完也能拖/点，装配只挂 scene 不动手势）
        view.isUserInteractionEnabled = true
        let pan = UIPanGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handlePan(_:)))
        pan.delegate = context.coordinator
        pan.cancelsTouchesInView = false
        view.addGestureRecognizer(pan)
        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handleTap))
        view.addGestureRecognizer(tap)
        // 让 SCNAction（点击的小动作）有持续渲染驱动
        view.isPlaying = true

        guard let url = Pet3DModelLocator.url(charId: charId) else { return view }

        // 异步加载（关键修复）：SCNScene 解码大模型要 1~2 秒，原来在主线程同步加载
        // 会把整条主线程冻住——弹形象面板点击没反应、选形象 2 秒才弹图标确认框、
        // 养成中心白圆卡死，全是它。后台解码，回主线程装配；面板秒开，模型稍后浮现。
        let coordinator = context.coordinator
        DispatchQueue.global(qos: .userInitiated).async {
            let scene = try? SCNScene(url: url, options: nil)
            DispatchQueue.main.async {
                guard !coordinator.tornDown, let scene else { return }   // 已销毁/加载失败保持空白
                Self.install(scene: scene, into: view, coordinator: coordinator)
            }
        }
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) { }

    /// 视图销毁时置标记，拦截在途异步装配
    static func dismantleUIView(_ uiView: SCNView, coordinator: Coordinator) {
        coordinator.tornDown = true
        coordinator.modelNode = nil
    }

    /// 装配已解码的 scene：节点收进容器平移到原点 + 相机取景 + 挂上视图（主线程执行）
    private static func install(scene: SCNScene, into view: SCNView, coordinator: Coordinator) {
        scene.background.contents = UIColor.clear
        let box = Self.worldBoundingBox(of: scene.rootNode)
        let center = SCNVector3((box.min.x + box.max.x) / 2,
                                (box.min.y + box.max.y) / 2,
                                (box.min.z + box.max.z) / 2)

        // 把全部模型节点收进一个容器，并平移到原点：拖转时才是原地自转。
        // 不平移的话（腾讯 OBJ 顶点坐标是 0~1，中心不在原点）会绕世界原点甩圈圈，
        // 转起来像旋转木马而不是转台。
        let modelNode = SCNNode()
        for child in scene.rootNode.childNodes {
            child.removeFromParentNode()
            modelNode.addChildNode(child)
        }
        modelNode.position = SCNVector3(-center.x, -center.y, -center.z)
        scene.rootNode.addChildNode(modelNode)
        coordinator.modelNode = modelNode

        Self.setUpCamera(scene: scene, radius: Self.radius(of: box))
        view.scene = scene
    }

    // MARK: - 相机：按模型半径自动取景（AI 出的模型通常没相机，得自己摆）。
    // 模型已平移到原点，相机对准原点即可。
    private static func setUpCamera(scene: SCNScene, radius: Float) {
        let camera = SCNCamera()
        camera.fieldOfView = 35
        camera.zNear = 0.01
        camera.zFar = 1000
        let camNode = SCNNode()
        camNode.camera = camera
        // 距离 = 半径 / tan(半视角)，再留 35% 余量，保证转圈时模型不出画
        // （全程用 Double 算三角函数再转 Float，避免 CGFloat/Double 重载歧义）
        let halfFOV = Double(camera.fieldOfView) / 2 * Double.pi / 180
        let distance = Float(Double(radius) / tan(halfFOV)) * 1.35
        camNode.position = SCNVector3(0, 0, max(distance, 0.5))
        camNode.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(camNode)
    }

    /// 包围盒最大边的一半，作为取景半径
    private static func radius(of box: (min: SCNVector3, max: SCNVector3)) -> Float {
        let extent = max(box.max.x - box.min.x,
                         max(box.max.y - box.min.y, box.max.z - box.min.z))
        return max(extent, 0.001) / 2
    }

    // MARK: - 世界坐标包围盒
    // SCNNode.boundingBox 只算节点自身的 geometry，不含子节点，
    // 所以遍历整棵树、把 8 个角变换到根节点空间后自己取并集。
    private static func worldBoundingBox(of root: SCNNode) -> (min: SCNVector3, max: SCNVector3) {
        var lo = SCNVector3(Float.greatestFiniteMagnitude, Float.greatestFiniteMagnitude, Float.greatestFiniteMagnitude)
        var hi = SCNVector3(-Float.greatestFiniteMagnitude, -Float.greatestFiniteMagnitude, -Float.greatestFiniteMagnitude)
        var hit = false

        root.enumerateHierarchy { node, _ in
            guard node.geometry != nil else { return }
            let (bMin, bMax) = node.boundingBox
            for x in [bMin.x, bMax.x] {
                for y in [bMin.y, bMax.y] {
                    for z in [bMin.z, bMax.z] {
                        let p = node.convertPosition(SCNVector3(x, y, z), to: root)
                        lo = SCNVector3(min(lo.x, p.x), min(lo.y, p.y), min(lo.z, p.z))
                        hi = SCNVector3(max(hi.x, p.x), max(hi.y, p.y), max(hi.z, p.z))
                        hit = true
                    }
                }
            }
        }
        // 一个 geometry 都没有（空文件 / 加载异常）：给个单位盒，免得相机算出 NaN
        return hit ? (lo, hi) : (SCNVector3(-0.5, -0.5, -0.5), SCNVector3(0.5, 0.5, 0.5))
    }
}

// MARK: - 统一入口：有 3D 模型走 SceneKit，没有走原来的平面帧动画
// 调用方继续保持 PetAnimationView 的参数口径，无模型时行为与改动前一致。
struct PetModelView: View {
    let action: String
    let charId: String
    let speed: AppSettings.AnimSpeed
    let size: CGFloat
    let loop: Bool
    let threeDEffect: Bool

    init(action: String,
         charId: String = "char1",
         speed: AppSettings.AnimSpeed = .mid,
         size: CGFloat = 120,
         loop: Bool = true,
         threeDEffect: Bool = false) {
        self.action = action
        self.charId = charId
        self.speed = speed
        self.size = size
        self.loop = loop
        self.threeDEffect = threeDEffect
    }

    var body: some View {
        if Pet3DModelLocator.hasModel(charId: charId) {
            SceneKitPetView(charId: charId)
                .frame(width: size, height: size)
        } else {
            PetAnimationView(
                action: action,
                charId: charId,
                speed: speed,
                size: size,
                loop: loop,
                threeDEffect: threeDEffect
            )
        }
    }
}