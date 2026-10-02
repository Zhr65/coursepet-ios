// MARK: - 数据备份 / 恢复（仅主 App 使用）
// 动机：免费签名 IPA 7 天过期，删掉重装会清空全部数据。
// 备份内容：App Group Documents 下的全部 JSON（课程/宠物/作业/专注）
//          + App Group UserDefaults 全部键值（宠物等级/设置等）
//          + standard UserDefaults 白名单（成就解锁记录）
// 格式：JSON（version + exportedAt + files + groupDefaults + standardDefaults）
import Foundation

enum BackupManager {
    private static let payloadVersion = 1

    /// 备份覆盖的 UserDefaults 键前缀（App Group 降级到 standard 时过滤系统键）
    private static let backupKeyPrefixes = ["pet.", "settings.", "focus.", "semester."]

    // MARK: - 导出
    /// 生成备份 JSON（分享前写入临时文件）
    static func makeBackupData() throws -> Data {
        // 1. 数据 JSON 文件（主存储：App Group 或本地兜底目录）
        //    注意：files 字典的 Value 必须是 String（base64），不能是 Data——
        //    JSONSerialization 遇到 Data 会抛 OC 异常（Swift try 接不住 → 直接闪退）
        let fm = FileManager.default
        var files: [String: String] = [:]

        let docs = StorageLocation.documentsDirectory
        if let items = try? fm.contentsOfDirectory(at: docs, includingPropertiesForKeys: nil) {
            for url in items where url.pathExtension.lowercased() == "json" {
                if let data = try? Data(contentsOf: url) {
                    files[url.lastPathComponent] = data.base64EncodedString()
                }
            }
        }
        // 本地降级目录也扫一遍：App Group 半失效时 saveJSON 会把数据写到这里，
        // 不扫会导致"实际生效的数据反而没进备份"
        let localFallback = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AppData", isDirectory: true)
        if localFallback != docs,
           let items = try? fm.contentsOfDirectory(at: localFallback, includingPropertiesForKeys: nil) {
            for url in items where url.pathExtension.lowercased() == "json" {
                if let data = try? Data(contentsOf: url) {
                    files[url.lastPathComponent] = data.base64EncodedString()
                }
            }
        }

        // 2. 偏好键值（按业务前缀过滤，避免把系统键打进备份）
        //    值必须经 jsonSafeValue 净化：UserDefaults 里可能存有 Date/URL 等类型，
        //    JSONSerialization 遇到它们会抛 OC 异常（Swift try 接不住 → 直接 SIGABRT 闪退）
        var groupDefaults: [String: Any] = [:]
        for (key, value) in StorageLocation.defaults.dictionaryRepresentation()
        where backupKeyPrefixes.contains(where: { key.hasPrefix($0) }) {
            if let safe = jsonSafeValue(value) { groupDefaults[key] = safe }
        }

        // 3. standard 白名单（成就）
        var standardDefaults: [String: Any] = [:]
        standardDefaults["achievement_ids"] = UserDefaults.standard.stringArray(forKey: "achievement_ids") ?? []

        let formatter = ISO8601DateFormatter()
        let payload: [String: Any] = [
            "app": "coursepet",
            "version": payloadVersion,
            "exportedAt": formatter.string(from: Date()),
            "files": files,
            "groupDefaults": groupDefaults,
            "standardDefaults": standardDefaults
        ]
        return try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted])
    }

    /// 备份文件的建议文件名
    static var suggestedFileName: String {
        let df = DateFormatter()
        df.calendar = Calendar(identifier: .gregorian)
        df.dateFormat = "yyyyMMdd-HHmm"
        return "coursepet-backup-\(df.string(from: Date())).json"
    }

    /// 把任意值净化为 JSON 可安全序列化的类型。
    /// 背景：JSONSerialization 遇到 NSDate/NSURL 等类型抛的是 OC 异常（非 Swift Error），
    /// Swift 的 try-catch 接不住，会直接 SIGABRT——必须在构造 payload 前完成转换。
    private static func jsonSafeValue(_ v: Any) -> Any? {
        switch v {
        case let s as String:  return s
        case let b as Bool:    return b
        case let n as NSNumber: return n           // Int/Double 等数值
        case let d as Date:    return ISO8601DateFormatter().string(from: d)
        case let u as URL:     return u.absoluteString
        case let data as Data: return data.base64EncodedString()
        case let arr as [Any]:
            return arr.compactMap { jsonSafeValue($0) }
        case let dict as [String: Any]:
            var out: [String: Any] = [:]
            for (k, val) in dict { if let sv = jsonSafeValue(val) { out[k] = sv } }
            return out
        default:
            return nil                              // 其余类型无法进 JSON，丢弃
        }
    }

    /// 生成备份并写入主 App 沙盒 Documents/Exports/（带日期文件名）。
    /// 配合 Info.plist 的 UIFileSharingEnabled：用户在 文件 App → 我的iPhone → CoursePet → Exports 直接取件。
    /// 完全不依赖系统分享面板（UIActivityViewController 在 iOS 26 必闪退，ShareLink 在 List 行内也有崩溃案例）。
    static func exportToDocuments() throws -> URL {
        let data = try makeBackupData()
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Exports", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let url = base.appendingPathComponent(suggestedFileName)
        try data.write(to: url, options: .atomic)
        return url
    }

    // MARK: - 恢复
    enum RestoreError: LocalizedError {
        case invalidFormat
        var errorDescription: String? {
            switch self {
            case .invalidFormat: return "这不是有效的 CoursePet 备份文件"
            }
        }
    }

    /// 从备份 JSON 恢复全部数据，成功后重载各存储的内存镜像
    static func restore(from data: Data) throws {
        guard
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            obj["app"] as? String == "coursepet",
            (obj["version"] as? Int ?? 0) <= payloadVersion,
            let files = obj["files"] as? [String: Any],
            let groupDefaults = obj["groupDefaults"] as? [String: Any]
        else {
            throw RestoreError.invalidFormat
        }

        let fm = FileManager.default
        // App Group 不可用时走本地兜底目录，与数据实际存储位置保持一致
        let docs = StorageLocation.documentsDirectory

        // 1. 写回 JSON 文件（JSONSerialization 下 Data 自动转 base64 还原为 Data；
        //    若是纯 base64 字符串形式也兜底支持）
        for (name, value) in files {
            if let d = value as? Data {
                try? d.write(to: docs.appendingPathComponent(name), options: .atomic)
            } else if let base64 = value as? String, let d = Data(base64Encoded: base64) {
                try? d.write(to: docs.appendingPathComponent(name), options: .atomic)
            }
        }

        // 2. 写回 UserDefaults（App Group 不可用时写 standard，与 StorageLocation 一致）
        let targetDefaults = StorageLocation.defaults
        for (key, value) in groupDefaults {
            if key.hasPrefix("NS") || key.hasPrefix("Apple") { continue } // 跳过系统键
            targetDefaults.set(value, forKey: key)
        }

        // 3. 成就
        if let std = obj["standardDefaults"] as? [String: Any],
           let achievements = std["achievement_ids"] as? [String] {
            UserDefaults.standard.set(achievements, forKey: "achievement_ids")
        }

        // 4. 重载内存镜像（DataManager / FocusStore 都在主线程）
        Task { @MainActor in
            DataManager.shared.reloadAll()
            FocusStore.shared.reload()
        }
    }
}
