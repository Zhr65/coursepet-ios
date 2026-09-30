// MARK: - 端侧长期记忆（零 VM 依赖）
// 思路与服务器端 memory 表一致，全部搬到本机：
//   1. 存储：UserDefaults JSON 数组（事实短文本，上限 50 条 FIFO，进程内缓存）
//   2. 提取：每轮对话结束后 fire-and-forget 调一次轻量 LLM（单轮、无工具、150 token），
//      问它"这轮对话有没有值得长期记住的用户事实"——没有就空输出，成本可忽略
//   3. 注入：AgentPromptBuilder.buildSystemPrompt 把最近 5 条写进 system prompt
// 失败静默：提取失败不影响对话主流程（宁可忘了也不打扰）。
import Foundation

struct AgentMemoryFact: Codable, Equatable {
    var fact: String
    var createdAt: Date
}

enum AgentMemoryStore {
    private static let key = "agent.memory.facts"
    private static let maxCount = 50
    private static var cache: [AgentMemoryFact]?

    static func loadAll() -> [AgentMemoryFact] {
        if let cache { return cache }
        guard let data = UserDefaults.standard.data(forKey: key),
              let items = try? JSONDecoder().decode([AgentMemoryFact].self, from: data) else {
            cache = []
            return []
        }
        cache = items
        return items
    }

    /// system prompt 注入用：按与 query 的相关性取 top-N（哈希嵌入余弦，LocalEmbedder
    /// 与服务器算法逐位对齐）；query 为空或记忆不多时回退"最近 N 条"。
    /// 解决"存了50条每次只见5条"的视野截断：相关旧事实（如过敏史）不再被新条目挤出视野。
    static func topFacts(query: String, limit: Int = 5) -> [String] {
        let items = loadAll()
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, items.count > limit else {
            return items.prefix(limit).map { $0.fact }
        }
        let qv = LocalEmbedder.embed(q)
        return Array(items
            .map { (fact: $0.fact, score: LocalEmbedder.cosine(qv, LocalEmbedder.embed($0.fact))) }
            .sorted { $0.score > $1.score }
            .prefix(limit)
            .map { $0.fact })
    }

    static var count: Int { loadAll().count }

    /// 记住一批事实（去重、长度过滤、FIFO 上限）
    static func remember(_ facts: [String]) {
        var items = loadAll()
        for raw in facts {
            let fact = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard fact.count >= 4, fact.count <= 120 else { continue }  // 太短是噪声，太长是复制粘贴
            if items.contains(where: { $0.fact == fact }) { continue }  // 完全相同跳过
            items.insert(AgentMemoryFact(fact: fact, createdAt: Date()), at: 0)
        }
        guard items != loadAll() else { return }
        if items.count > maxCount { items = Array(items.prefix(maxCount)) }
        persist(items)
    }

    static func clear() {
        cache = []
        UserDefaults.standard.removeObject(forKey: key)
    }

    /// 删除单条（记忆管理页左滑删除用）
    static func remove(_ fact: String) {
        var items = loadAll()
        items.removeAll { $0.fact == fact }
        persist(items)
    }

    private static func persist(_ items: [AgentMemoryFact]) {
        cache = items
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    // MARK: 每轮对话后的提取入口（sendOnDevice 最终回答后调用）
    static func maybeExtractFrom(lastUser: String, lastAnswer: String) async {
        let config = AgentConfigStore.load()
        guard config.isConfigured else { return }
        let system = """
        你从对话中提取值得长期记住的用户事实（如复习计划、考试目标、专业、偏好、习惯）。
        只输出事实本身，每行一条，最多 2 条；没有值得记的就什么都不输出。
        禁止编造，禁止解释，禁止输出与用户无关的宠物台词。
        """
        let user = "用户说：\(String(lastUser.prefix(300)))\n宠物回复：\(String(lastAnswer.prefix(300)))"
        guard let answer = try? await LiteLLM.complete(system: system, user: user, config: config) else { return }
        let facts = answer
            .split(whereSeparator: \.isNewline)
            .map { line in
                line.trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "-•·0123456789. "))
            }
            .filter { !$0.isEmpty }
        remember(facts)
    }
}

/// 单轮轻量 LLM 调用（无工具、无历史）：记忆提取等辅助任务专用。
/// 与 AgentEngine.callLLM 同一配置通道（OpenAI 兼容 /chat/completions）。
enum LiteLLM {
    static func complete(system: String, user: String, config: AgentConfig,
                         maxTokens: Int = 150) async throws -> String {
        let body: [String: Any] = [
            "model": config.model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
            "temperature": 0.2,
            "max_tokens": maxTokens,
        ]
        var request = URLRequest(url: URL(string: config.baseURL + "/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, httpResponse) = try await URLSession.shared.data(for: request)
        guard (httpResponse as? HTTPURLResponse)?.statusCode == 200 else {
            throw AgentEngineError.network
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw AgentEngineError.badResponse
        }
        return content
    }
}
