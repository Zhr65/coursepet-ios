// MARK: - 统一存储位置解析器
// 数据 JSON 落盘位置：优先 App Group 共享容器（主 App / Widget / 灵动岛三端共享）；
// 免费签名等场景下 App Group 权限可能签不进去（containerURL 返回 nil），
// 旧实现在此静默失败 → 所有数据只活在内存里，杀掉后台全部丢失。
// 现在自动降级到本地沙盒 Documents/AppData：数据永远持久，仅小组件无法跨进程读取。
import Foundation

enum StorageLocation {
    /// App Group 共享容器（权限有效时非 nil）
    static var containerURL: URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: DataManager.appGroupID
        )
    }

    /// 当前是否使用 App Group 共享存储（设置页诊断显示用）
    static var usesAppGroup: Bool { containerURL != nil }

    /// 数据 JSON 目录：App Group Documents → 本地沙盒 Documents/AppData 兜底
    static var documentsDirectory: URL {
        if let url = containerURL {
            return url.appendingPathComponent("Documents", isDirectory: true)
        }
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("AppData", isDirectory: true)
    }

    /// 偏好 UserDefaults：App Group suite 不可用时回退 standard
    static var defaults: UserDefaults {
        UserDefaults(suiteName: DataManager.appGroupID) ?? .standard
    }
}
