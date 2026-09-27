// MARK: - Agent 配置存取（API Key 走 Keychain，其余走 UserDefaults）
// 为什么 API Key 不放 UserDefaults：UserDefaults 是明文 plist，越狱设备可直接读取；
// Keychain 由系统加密保护，且卸载 App 也不会清除。这是面试必问的安全常识点。
// 兜底说明：免签名构建环境下 Keychain 可能因缺少 entitlement 失败，
// 此时降级 UserDefaults 并给出标记，保证功能可用（与 App Group 降级同一思路）。
import Foundation
import Security

enum AgentConfigStore {

    private static let defaults = UserDefaults.standard
    private static let baseURLKey = "agent.baseURL"
    private static let modelKey = "agent.model"
    private static let keychainFallbackKey = "agent.apiKey.fallback"
    private static let keychainService = "com.coursepet.agent"
    private static let keychainAccount = "apiKey"

    /// 读取完整配置（Keychain 优先，失败降级 UserDefaults）
    static func load() -> AgentConfig {
        var config = AgentConfig.default
        config.baseURL = defaults.string(forKey: baseURLKey) ?? config.baseURL
        config.model = defaults.string(forKey: modelKey) ?? config.model
        config.apiKey = keychainRead() ?? defaults.string(forKey: keychainFallbackKey) ?? ""
        return config
    }

    /// 保存配置：Key 进 Keychain（失败自动降级），URL/模型进 UserDefaults
    static func save(baseURL: String, model: String, apiKey: String) {
        let trimmedURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        defaults.set(trimmedURL.isEmpty ? AgentConfig.default.baseURL : trimmedURL, forKey: baseURLKey)
        defaults.set(trimmedModel.isEmpty ? AgentConfig.default.model : trimmedModel, forKey: modelKey)

        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if keychainWrite(trimmedKey) {
            // 写入成功则清掉旧降级数据
            defaults.removeObject(forKey: keychainFallbackKey)
        } else {
            // Keychain 不可用（免签名构建常见）：降级 UserDefaults 保功能可用
            defaults.set(trimmedKey, forKey: keychainFallbackKey)
        }
    }

    /// Keychain 是否真正可用（设置页展示提示用）
    static var keychainAvailable: Bool {
        keychainWrite("probe") && keychainRead() == "probe"
    }

    // MARK: - Keychain 基础读写（Generic Password 类型）

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
    }

    private static func keychainWrite(_ value: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        // 先删旧值（Keychain 对同 key 重复写入会报 duplicate）
        SecItemDelete(baseQuery() as CFDictionary)
        var attributes = baseQuery()
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    private static func keychainRead() -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject? = nil
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
