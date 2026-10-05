// MARK: - 桌面图标跟随宠物形象（Alternate App Icons）
// 图标 PNG 平铺在主 bundle 根目录（project.yml 的 AltIcons 资源，group 方式），
// Info.plist 的 CFBundleIcons → CFBundleAlternateIcons 声明 PetIcon1~9；
// 切换调 setAlternateIconName —— 系统必弹「图标已更改」确认框（苹果不允许去掉）。
import UIKit

enum AppIconSync {
    /// 形象 → 备选图标名（charN ↔ PetIconN，与 AltIcons 资源一一对应）
    private static let iconNames: [String: String] = [
        "char1": "PetIcon1", "char2": "PetIcon2", "char3": "PetIcon3",
        "char4": "PetIcon4", "char5": "PetIcon5", "char6": "PetIcon6",
        "char7": "PetIcon7", "char8": "PetIcon8", "char9": "PetIcon9",
        "char10": "PetIcon10", "char11": "PetIcon11", "char12": "PetIcon12",
        "char13": "PetIcon13", "char14": "PetIcon14", "char15": "PetIcon15",
    ]

    /// 跟随开关（默认开：换形象顺手换桌面图标）
    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "pet.iconFollowsAvatar") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "pet.iconFollowsAvatar") }
    }

    /// 形象切换后同步桌面图标；开关关 / 该形象没有备选图标 / 目标与当前一致时不动作。
    /// 无备选图标的形象（新加的形象还没配图标）直接跳过，避免把桌面图标回落成默认图标
    static func sync(charId: String) {
        guard isEnabled else { return }
        guard let target = iconNames[charId] else { return }
        guard UIApplication.shared.alternateIconName != target else { return }
        UIApplication.shared.setAlternateIconName(target) { error in
            if let error {
                print("[AppIconSync] ⚠️ 图标切换失败 \(charId)：\(error.localizedDescription)")
            } else {
                print("[AppIconSync] ✅ 桌面图标已切换为 \(target)")
            }
        }
    }
}
