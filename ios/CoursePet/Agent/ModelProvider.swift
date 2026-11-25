// MARK: - 模型服务（多 provider 自主接入）
// 为什么要有这一层：端侧 Agent 原来只能配一套 baseURL/key/model，换模型要手改三个字段，
// 旧配置直接丢；也没法在不同服务商之间切换比较。
// 现在拆成「多个 provider + 一个当前选中」，AgentConfigStore.load() 返回选中项映射出的
// AgentConfig —— AgentEngine / AgentQuickLLM / AgentImageGen 等所有调用方一行都不用改。
//
// 存储位置（与 AgentConfigStore 同一策略：Keychain 主体 + UserDefaults 镜像）：
//   · provider 列表（不含 Key）：Keychain account "providerList"
//   · 每个 provider 的 Key：Keychain account "provider.<id>"，绝不写进 UserDefaults 明文
//   · 当前选中 id：Keychain account "providerActive"
// 这样删 App 重装（免费签名证书轮换的必然操作）后配置仍然读得回来。
import Foundation

struct ModelProvider: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var baseURL: String
    var model: String
    var visionModel: String

    init(id: String = UUID().uuidString,
         name: String,
         baseURL: String,
         model: String,
         visionModel: String = "") {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.model = model
        self.visionModel = visionModel
    }

    /// 端点统一按 OpenAI 兼容约定拼 chat/completions（各家兼容层都是这个路径）
    var chatURL: URL? {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let base = trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
        return URL(string: base + "/chat/completions")
    }
}

enum ModelProviderStore {

    private static let defaults = UserDefaults.standard
    private static let listAccount = "providerList"
    private static let activeAccount = "providerActive"
    private static let listMirrorKey = "agent.providerList.mirror"
    private static let activeMirrorKey = "agent.providerActive"
    private static let keyMirrorPrefix = "agent.providerKey."

    // MARK: - 预设
    // 只给端点和常用模型名，Key 由用户自己填。模型名会随服务商更新迭代，
    // 用户可以在编辑页改名，这里不做「自动跟随最新」——猜一个不存在的模型名比让他手改更烦。
    static var presets: [ModelProvider] {
        [
            ModelProvider(name: "DeepSeek 官方",
                          baseURL: "https://api.deepseek.com/v1",
                          model: "deepseek-chat"),
            ModelProvider(name: "智谱 GLM",
                          baseURL: "https://open.bigmodel.cn/api/paas/v4",
                          model: "glm-4.6"),
            ModelProvider(name: "通义千问",
                          baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1",
                          model: "qwen-plus"),
            ModelProvider(name: "自定义（中转站 / Ollama / 自建）",
                          baseURL: "",
                          model: "")
        ]
    }

    // MARK: - 列表

    static var all: [ModelProvider] {
        if let json = AgentConfigStore.readExtraKey(account: listAccount),
           let data = json.data(using: .utf8),
           let list = try? JSONDecoder().decode([ModelProvider].self, from: data) {
            return list
        }
        // Keychain 不可用的免签名构建：走 UserDefaults 镜像
        if let json = defaults.string(forKey: listMirrorKey),
           let data = json.data(using: .utf8),
           let list = try? JSONDecoder().decode([ModelProvider].self, from: data) {
            return list
        }
        return []
    }

    static func saveAll(_ list: [ModelProvider]) {
        guard let data = try? JSONEncoder().encode(list),
              let json = String(data: data, encoding: .utf8) else { return }
        _ = AgentConfigStore.writeExtraKey(json, account: listAccount)
        defaults.set(json, forKey: listMirrorKey)
    }

    // MARK: - 当前选中

    static var activeId: String? {
        if let id = AgentConfigStore.readExtraKey(account: activeAccount), !id.isEmpty {
            return id
        }
        let mirrored = defaults.string(forKey: activeMirrorKey)
        return (mirrored?.isEmpty == false) ? mirrored : nil
    }

    static func setActive(_ id: String) {
        _ = AgentConfigStore.writeExtraKey(id, account: activeAccount)
        defaults.set(id, forKey: activeMirrorKey)
    }

    /// 当前生效的 provider。指向已删除的 id 时回落到第一个，保证永远有默认项，
    /// 不出现「列表里有东西但 load() 返回未配置」这种自相矛盾的状态。
    static func active() -> ModelProvider? {
        let list = all
        guard !list.isEmpty else { return nil }
        if let id = activeId, let hit = list.first(where: { $0.id == id }) {
            return hit
        }
        return list.first
    }

    // MARK: - 增删改

    /// apiKey 传 nil = 不改 Key（编辑页没动输入框时用）；传空串 = 清空
    static func upsert(_ provider: ModelProvider, apiKey: String? = nil) {
        var list = all
        if let idx = list.firstIndex(where: { $0.id == provider.id }) {
            list[idx] = provider
        } else {
            list.append(provider)
        }
        saveAll(list)
        if let key = apiKey { saveAPIKey(key, for: provider.id) }
        if activeId == nil { setActive(provider.id) }
    }

    static func remove(_ id: String) {
        var list = all
        list.removeAll { $0.id == id }
        saveAll(list)
        _ = AgentConfigStore.writeExtraKey("", account: keyAccount(id))
        defaults.removeObject(forKey: keyMirrorPrefix + id)
        // 删的正好是当前选中 → 顺位到第一个；列表空了就把选中标记也清掉
        if activeId == id {
            if let first = list.first {
                setActive(first.id)
            } else {
                _ = AgentConfigStore.writeExtraKey("", account: activeAccount)
                defaults.removeObject(forKey: activeMirrorKey)
            }
        }
    }

    // MARK: - Key 存取（每个 provider 独立条目）

    private static func keyAccount(_ id: String) -> String { "provider." + id }

    static func apiKey(for id: String) -> String {
        if let key = AgentConfigStore.readExtraKey(account: keyAccount(id)), !key.isEmpty {
            return key
        }
        return defaults.string(forKey: keyMirrorPrefix + id) ?? ""
    }

    static func saveAPIKey(_ key: String, for id: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = AgentConfigStore.writeExtraKey(trimmed, account: keyAccount(id))
        defaults.set(trimmed, forKey: keyMirrorPrefix + id)
    }

    // MARK: - 老配置迁移
    // 老版本只有一套配置（Keychain account "apiKey" + agentConfig blob）。
    // 首次进入模型管理时把它变成一条正常 provider，用户不用重填。
    // 注意必须走 loadLegacy()：load() 内部会读 provider，这里再调会绕回自己。
    static func ensureMigrated() {
        guard all.isEmpty else { return }
        let legacy = AgentConfigStore.loadLegacy()
        guard legacy.isConfigured else { return }
        let name = legacy.model.isEmpty ? "当前模型" : legacy.model
        let provider = ModelProvider(name: name,
                                     baseURL: legacy.baseURL,
                                     model: legacy.model,
                                     visionModel: legacy.visionModel)
        saveAll([provider])
        saveAPIKey(legacy.apiKey, for: provider.id)
        setActive(provider.id)
    }

    // MARK: - 连通性测试
    // 用一次 max_tokens=1 的最小对话请求判活：GET /models 很多中转站不支持，
    // 而且它只能证明鉴权过，证明不了「这个模型名能用」。
    static func testConnectivity(provider: ModelProvider, apiKey: String) async -> String {
        guard let url = provider.chatURL else { return "❌ 接口地址是空的" }
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "❌ 还没填 API Key"
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))",
                         forHTTPHeaderField: "Authorization")
        let body: [String: Any] = [
            "model": provider.model,
            "messages": [["role": "user", "content": "ping"]],
            "max_tokens": 1,
            "stream": false
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, resp) = try await URLSession.shared.data(for: request)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            switch code {
            case 200:
                return "✅ 连通，模型 \(provider.model) 可用"
            case 401, 403:
                return "❌ Key 无效或无权限（HTTP \(code)）"
            case 404:
                return "❌ 地址或模型名不对（404），检查后缀是否要带 /v1"
            case 429:
                return "⚠️ 被限流（429），配置本身没问题，等一会儿再试"
            default:
                // 把后端错误消息带出来，比只给状态码好定位（很多中转站会在 detail 里写原因）
                if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let err = obj["error"] as? [String: Any],
                   let msg = err["message"] as? String {
                    return "❌ HTTP \(code)：\(msg.prefix(80))"
                }
                return "❌ HTTP \(code)"
            }
        } catch {
            return "❌ 连不上：\(error.localizedDescription)"
        }
    }
}
