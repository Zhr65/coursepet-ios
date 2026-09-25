// MARK: - 宠物 PNG 帧资源安装器
// 把打包进 App Bundle 的 AppPetAssets/char1~char4 帧图拷贝到
// App Group 容器 Documents/PetAnimations/{charId}/，供主 App、
// Widget、Live Activity 三端通过 PetAnimationView 读取。
// 已安装过（存在标记帧）则跳过，避免重复 IO。
import Foundation

enum PetAssetInstaller {
    /// 全部可用形象 ID（与 Bundle 内 AppPetAssets 子目录一一对应）
    static let allCharIds = ["char1", "char2", "char3", "char4"]
    /// 全部动作（与 pet_{action}_{frame}.png 命名对应）
    static let allActions = ["idle", "happy", "excite", "walk", "listen",
                             "sleep", "charge", "nervous", "weak", "rain"]
    /// 每个动作的帧数
    static let framesPerAction = 8

    /// 主 App 启动时调用：逐个角色检查并安装
    static func installIfNeeded() {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.coursepet.app"
        ) else {
            print("[PetAssetInstaller] ⚠️ App Group 不可用，跳过安装")
            return
        }
        let baseDir = container
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("PetAnimations", isDirectory: true)

        for charId in allCharIds {
            let destDir = baseDir.appendingPathComponent(charId, isDirectory: true)
            let marker = destDir.appendingPathComponent("pet_idle_0.png")
            // 标记帧已存在说明该角色已安装过，跳过
            if FileManager.default.fileExists(atPath: marker.path) { continue }

            do {
                try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
            } catch {
                print("[PetAssetInstaller] ⚠️ 创建目录失败 \(charId)：\(error)")
                continue
            }

            var installed = 0
            for action in allActions {
                for frame in 0..<framesPerAction {
                    // 从 Bundle 的 folder reference（AppPetAssets/charX/）取帧图
                    guard let src = Bundle.main.url(
                        forResource: "pet_\(action)_\(frame)",
                        withExtension: "png",
                        subdirectory: "AppPetAssets/\(charId)"
                    ) else { continue }
                    let dst = destDir.appendingPathComponent("pet_\(action)_\(frame).png")
                    do {
                        try FileManager.default.removeItem(at: dst)
                    } catch { /* 目标不存在时忽略 */ }
                    do {
                        try FileManager.default.copyItem(at: src, to: dst)
                        installed += 1
                    } catch {
                        print("[PetAssetInstaller] ⚠️ 拷贝失败 \(charId)/\(action)/\(frame)：\(error)")
                    }
                }
            }
            print("[PetAssetInstaller] ✅ \(charId) 安装完成，共 \(installed) 帧")
        }
    }
}
