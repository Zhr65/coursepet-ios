// MARK: - Agent 配置存取（主存储 Keychain，UserDefaults 仅作镜像兜底）
// 为什么配置不放 UserDefaults：本 App 由 Codemagic 构建未签名 IPA，再用 AltStore 免费签名安装，
// 证书轮换后必须删除 App 重装——沙盒（UserDefaults/文件）随删除全部清空，配置每次都要重填；
// Keychain 条目绑定签名团队，删除重装后仍可读回。因此所有 Agent 配置（API Key/端点/服务器三件套）
// 主体存 Keychain，UserDefaults 同步镜像：Keychain 在当前环境不可用时兜底 + 兼容旧版本数据自动迁移。
import Foundation
import Security

enum AgentConfigStore {

    private static let defaults = UserDefaults.standard
    private static let baseURLKey = "agent.baseURL"
    private static let modelKey = "agent.model"
    private static let keychainFallbackKey = "agent.apiKey.fallback"
    private static let keychainService = "com.coursepet.agent"

    // Keychain 条目按账号分片：API Key / 端点配置 / 服务器配置互不覆盖
    private static let keychainAccount = "apiKey"
    private static let agentBlobAccount = "agentConfig"     // baseURL + model
    private static let serverBlobAccount = "serverConfig"   // url + user + pass
    private static let probeAccount = "probe"               // 可用性探针，不存真实数据

    // UserDefaults 镜像键（服务器三件套；Keychain 不可用时兜底读取）
    private static let serverURLKey = "agent.serverURL"
    private static let serverUserKey = "agent.serverUser"
    private static let serverPassKey = "agent.serverPass"

    // MARK: V2 服务器模式配置
    struct ServerConfig: Codable, Equatable {
        var baseURL = ""
        var username = ""
        var password = ""
        /// 三项齐全才启用服务器模式；清空地址即回退端侧 Agent
        var isConfigured: Bool { !baseURL.isEmpty && !username.isEmpty && !password.isEmpty }
    }

    static func loadServerConfig() -> ServerConfig {
        // Keychain 优先（删 App 重装后仍在）；读不到再回退 UserDefaults（旧版本数据）
        if let json = keychainRead(account: serverBlobAccount),
           let config = try? JSONDecoder().decode(ServerConfig.self, from: Data(json.utf8)) {
            return config
        }
        let fallback = ServerConfig(
            baseURL: defaults.string(forKey: serverURLKey) ?? "",
            username: defaults.string(forKey: serverUserKey) ?? "",
            password: defaults.string(forKey: serverPassKey) ?? ""
        )
        // 旧数据一次性迁移进 Keychain（之后重装也能读回）
        if fallback != ServerConfig() {
            saveServerConfig(url: fallback.baseURL, user: fallback.username, pass: fallback.password)
        }
        return fallback
    }

    static func saveServerConfig(url: String, user: String, pass: String) {
        let config = ServerConfig(
            baseURL: url.trimmingCharacters(in: .whitespacesAndNewlines),
            username: user.trimmingCharacters(in: .whitespacesAndNewlines),
            password: pass.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        writeBlob(config, account: serverBlobAccount)
        // UserDefaults 镜像（Keychain 不可用时兜底）
        defaults.set(config.baseURL, forKey: serverURLKey)
        defaults.set(config.username, forKey: serverUserKey)
        defaults.set(config.password, forKey: serverPassKey)
    }

    /// 读取完整配置（Keychain 优先 → UserDefaults 兜底；兜底命中时自动迁移进 Keychain）
    static func load() -> AgentConfig {
        var config = AgentConfig.default
        var needsMigration = false

        // baseURL / model / visionModel：Keychain blob 优先
        if let blob = readBlob([String: String].self, account: agentBlobAccount) {
            if let url = blob["baseURL"], !url.isEmpty { config.baseURL = url }
            if let model = blob["model"], !model.isEmpty { config.model = model }
            if let vision = blob["visionModel"] { config.visionModel = vision }
        } else {
            config.baseURL = defaults.string(forKey: baseURLKey) ?? config.baseURL
            config.model = defaults.string(forKey: modelKey) ?? config.model
            needsMigration = true
        }

        // API Key：Keychain 优先 → UserDefaults 降级数据。
        // "probe" 是旧版本可用性探针误写入真实条目的毒数据（会导致 401），识别为无效并触发迁移
        if let key = keychainRead(account: keychainAccount), key != "probe" {
            config.apiKey = key
        } else if let key = defaults.string(forKey: keychainFallbackKey), !key.isEmpty, key != "probe" {
            config.apiKey = key
            needsMigration = true
        }

        // 旧数据一次性迁移：此后删除重装也能读回
        if needsMigration {
            writeBlob(["baseURL": config.baseURL, "model": config.model, "visionModel": config.visionModel], account: agentBlobAccount)
            if keychainWrite(config.apiKey, account: keychainAccount) {
                defaults.removeObject(forKey: keychainFallbackKey)
            }
        }
        return config
    }

    /// 保存配置：主体进 Keychain（删除重装不丢），UserDefaults 同步镜像兜底
    static func save(baseURL: String, model: String, apiKey: String, visionModel: String = "") {
        let trimmedURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedVision = visionModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let effURL = trimmedURL.isEmpty ? AgentConfig.default.baseURL : trimmedURL
        let effModel = trimmedModel.isEmpty ? AgentConfig.default.model : trimmedModel

        writeBlob(["baseURL": effURL, "model": effModel, "visionModel": trimmedVision], account: agentBlobAccount)
        defaults.set(effURL, forKey: baseURLKey)
        defaults.set(effModel, forKey: modelKey)

        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !keychainWrite(trimmedKey, account: keychainAccount) {
            // Keychain 不可用（免签名构建常见）：降级 UserDefaults 保功能可用
            defaults.set(trimmedKey, forKey: keychainFallbackKey)
        }
    }

    // MARK: - 第三方扩展 Key 存取（图像生成等独立 Key：复用同一条目体系，account 分片隔离）

    /// 独立 Key 写入（如阿里百炼 dashscopeKey），返回是否写入成功
    static func writeExtraKey(_ value: String, account: String) -> Bool {
        keychainWrite(value, account: account)
    }

    /// 独立 Key 读取
    static func readExtraKey(account: String) -> String? {
        keychainRead(account: account)
    }

    /// Keychain 是否真正可用（设置页展示提示用；独立探针条目，不污染真实配置）
    static var keychainAvailable: Bool {
        let ok = keychainWrite("probe", account: probeAccount) && keychainRead(account: probeAccount) == "probe"
        SecItemDelete(baseQuery(account: probeAccount) as CFDictionary)
        return ok
    }

    // MARK: - Keychain 基础读写（Generic Password 类型）

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account
        ]
    }

    private static func keychainWrite(_ value: String, account: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        // 先删旧值（Keychain 对同 key 重复写入会报 duplicate）
        SecItemDelete(baseQuery(account: account) as CFDictionary)
        var attributes = baseQuery(account: account)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    private static func keychainRead(account: String) -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject? = nil
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Codable blob 存取（JSON 序列化进 Keychain 单条目）

    private static func writeBlob<T: Encodable>(_ value: T, account: String) {
        guard let data = try? JSONEncoder().encode(value),
              let json = String(data: data, encoding: .utf8) else { return }
        keychainWrite(json, account: account)
    }

    private static func readBlob<T: Decodable>(_ type: T.Type, account: String) -> T? {
        guard let json = keychainRead(account: account), let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
