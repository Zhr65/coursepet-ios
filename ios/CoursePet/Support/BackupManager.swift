// MARK: - 数据备份 / 恢复（仅主 App 使用）
// 动机：免费签名 IPA 7 天过期，删掉重装会清空全部数据。
// 备份内容：App Group Documents 下的全部 JSON（课程/宠物/作业/专注）
//          + App Group UserDefaults 全部键值（宠物等级/设置等）
//          + standard UserDefaults 白名单（成就解锁记录）
// 格式：JSON（version + exportedAt + files + groupDefaults + standardDefaults）
import Foundation

enum BackupManager {
    private static let payloadVersion = 1

    // MARK: - 导出
    /// 生成备份 JSON（分享前写入临时文件）
    static func makeBackupData() throws -> Data {
        let fm = FileManager.default
        var files: [String: Data] = [:]

        // 1. App Group Documents 下所有 JSON 文件
        if let docs = fm.containerURL(
            forSecurityApplicationGroupIdentifier: DataManager.appGroupID
        )?.appendingPathComponent("Documents", isDirectory: true),
           let items = try? fm.contentsOfDirectory(at: docs, includingPropertiesForKeys: nil) {
            for url in items where url.pathExtension.lowercased() == "json" {
                if let data = try? Data(contentsOf: url) {
                    files[url.lastPathComponent] = data
                }
            }
        }

        // 2. App Group UserDefaults 全部键值（plist 原生类型可直接进 JSON）
        var groupDefaults: [String: Any] = [:]
        if let suite = UserDefaults(suiteName: DataManager.appGroupID) {
            for (key, value) in suite.dictionaryRepresentation() {
                groupDefaults[key] = value
            }
        }

        // 3. standard UserDefaults 白名单（成就）
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
        df.dateFormat = "yyyyMMdd-HHmm"
        return "coursepet-backup-\(df.string(from: Date())).json"
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
        guard let docs = fm.containerURL(
            forSecurityApplicationGroupIdentifier: DataManager.appGroupID
        )?.appendingPathComponent("Documents", isDirectory: true) else {
            throw RestoreError.invalidFormat
        }

        // 1. 写回 JSON 文件（JSONSerialization 下 Data 自动转 base64 还原为 Data；
        //    若是纯 base64 字符串形式也兜底支持）
        for (name, value) in files {
            if let d = value as? Data {
                try? d.write(to: docs.appendingPathComponent(name), options: .atomic)
            } else if let base64 = value as? String, let d = Data(base64Encoded: base64) {
                try? d.write(to: docs.appendingPathComponent(name), options: .atomic)
            }
        }

        // 2. 写回 App Group UserDefaults
        if let suite = UserDefaults(suiteName: DataManager.appGroupID) {
            for (key, value) in groupDefaults {
                if key.hasPrefix("NS") || key.hasPrefix("Apple") { continue } // 跳过系统键
                suite.set(value, forKey: key)
            }
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
