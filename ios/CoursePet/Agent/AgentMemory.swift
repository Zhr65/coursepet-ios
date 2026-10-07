// MARK: - 端侧长期记忆（零 VM 依赖）
// 与服务器端 MemoryEntry 表同思路，全部搬到本机：
//   1. 存储：UserDefaults JSON 数组（上限 200 条，进程内缓存；每条带 kind 分类与 source 来源）
//   2. 提取：每 3 轮对话后 fire-and-forget 调一次轻量 LLM，对照已有记忆输出
//      memory_diff（add 新增 / update 修正 / forget 过时）——端侧存储简单，update/forget 直接改删
//   3. 注入：AgentPromptBuilder.buildSystemPrompt 按 kind 分组取相关条目写进 system prompt
//   4. 服务器模式镜像：服务器提炼落库后，客户端拉 /agent/memory 合并进本地（管理页秒开、切模式不丢）
// 失败静默：提取/同步失败不影响对话主流程（宁可忘了也不打扰）。
import Foundation

struct AgentMemoryFact: Codable, Equatable {
    var fact: String
    var createdAt: Date
    // 以下字段后加，老数据 JSON 缺失时合成解码自动给 nil（decodeIfPresent）
    var kind: String?      // fact/preference/person/promise，nil 视为 fact
    var source: String?    // auto=端侧自动提炼 / server=服务器镜像同步，nil 视为 auto

    var resolvedKind: String { (kind ?? "fact") }
    var sourceLabel: String {
        switch source {
        case "server": return "服务器同步"
        case "auto": return "聊天里记住的"
        default: return "聊天里记住的"
        }
    }
}

enum AgentMemoryStore {
    private static let key = "agent.memory.facts"
    private static let maxCount = 200
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
    /// 解决"存了很多条每次只见几条"的视野截断：相关旧事实（如过敏史）不再被新条目挤出视野。
    static func topEntries(query: String, limit: Int = 8) -> [(kind: String, fact: String)] {
        let items = loadAll()
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let picked: [AgentMemoryFact]
        if !q.isEmpty, items.count > limit {
            let qv = LocalEmbedder.embed(q)
            picked = items
                .map { (item: $0, score: LocalEmbedder.cosine(qv, LocalEmbedder.embed($0.fact))) }
                .sorted { $0.score > $1.score }
                .prefix(limit)
                .map { $0.item }
        } else {
            picked = Array(items.prefix(limit))
        }
        return picked.map { ($0.resolvedKind, $0.fact) }
    }

    static var count: Int { loadAll().count }

    /// kind → 中文分组名（管理页分组与 system prompt 注入共用同一套）
    static func kindLabel(_ kind: String?) -> String {
        switch kind ?? "fact" {
        case "preference": return "偏好"
        case "person": return "提到的人"
        case "promise": return "答应的事"
        default: return "它记住的事"
        }
    }

    /// 记住一批事实（自动提炼入口：去重、长度过滤、FIFO 上限）
    static func remember(_ facts: [String]) {
        var items = loadAll()
        for raw in facts {
            let fact = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard fact.count >= 4, fact.count <= 120 else { continue }  // 太短是噪声，太长是复制粘贴
            if items.contains(where: { $0.fact == fact }) { continue }  // 完全相同跳过
            items.insert(AgentMemoryFact(fact: fact, createdAt: Date(), kind: nil, source: "auto"), at: 0)
        }
        guard items != loadAll() else { return }
        if items.count > maxCount { items = Array(items.prefix(maxCount)) }
        persist(items)
    }

    /// 管理页手动加一条（source=manual）
    static func addManual(_ text: String) {
        let fact = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard fact.count >= 2, fact.count <= 180 else { return }
        var items = loadAll()
        guard !items.contains(where: { $0.fact == fact }) else { return }
        items.insert(AgentMemoryFact(fact: fact, createdAt: Date(), kind: nil, source: "manual"), at: 0)
        if items.count > maxCount { items = Array(items.prefix(maxCount)) }
        persist(items)
    }

    /// 管理页编辑一条（按旧原文定位，原地改内容）
    static func update(_ oldFact: String, to newFact: String) {
        let trimmed = newFact.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2, trimmed.count <= 180 else { return }
        var items = loadAll()
        guard let idx = items.firstIndex(where: { $0.fact == oldFact }) else { return }
        items[idx].fact = trimmed
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

    // MARK: 服务器记忆镜像（服务器模式专用）
    /// 拉 /agent/memory 合并进本地：按内容去重，服务器没有而本地标记为 server 来源的条目清掉
    /// （服务器侧删了，镜像跟着删；本地 auto/manual 的条目不受影响）。
    /// 管理页秒开缓存 + 切回端侧模式后注入仍有货。失败静默。
    static func syncServerMirror() async {
        let server = AgentConfigStore.loadServerConfig()
        guard server.isConfigured else { return }
        guard let token = try? await AgentRemoteClient.ensureToken(
            baseURL: server.baseURL, username: server.username, password: server.password),
              let url = URL(string: AgentRemoteClient.trimmedBase(server.baseURL) + "/agent/memory") else { return }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = obj["items"] as? [[String: Any]] else { return }

        var items = loadAll()
        // 先清掉本地旧的 server 镜像条目（服务器侧已删的不再留着）
        items.removeAll { $0.source == "server" }
        // 合并服务器当前列表（服务器顺序新→旧，本地 insert(0:) 后保持一致）
        for row in rows.reversed() {
            guard let fact = row["fact"] as? String, fact.count >= 2 else { continue }
            if items.contains(where: { $0.fact == fact }) { continue }
            let kind = row["kind"] as? String
            items.insert(AgentMemoryFact(fact: fact, createdAt: Date(), kind: kind, source: "server"), at: 0)
        }
        if items.count > maxCount { items = Array(items.prefix(maxCount)) }
        persist(items)
    }

    // MARK: 每轮对话后的提取入口（sendOnDevice 最终回答后调用）
    /// 提取降频计数：每轮都调小 LLM 是免费档限流的主要放大器之一，
    /// 改为每 3 轮提取一次（内存计数，重启归零无碍——少提一轮不丢关键事实）
    private static var roundCounter = 0

    static func maybeExtractFrom(lastUser: String, lastAnswer: String) async {
        roundCounter += 1
        guard roundCounter % 3 == 1 else { return }   // 第 1、4、7…轮才提取
        let config = AgentConfigStore.load()
        guard config.isConfigured else { return }
        let existing = loadAll().prefix(30).map { $0.fact }
        let existingText = existing.isEmpty ? "（还没有任何记忆）" : existing.joined(separator: "\n")
        let system = """
        你从一段校园助手对话里维护主人的长期记忆（分四类：fact 事实 / preference 偏好 / person 重要的人 / promise 承诺）。
        对照已知记忆，只输出一个 JSON 对象，不要输出任何其他内容：
        {"add":[{"kind":"fact","content":"一句话新记忆"}],"update":[{"old":"要修改的旧记忆原文","kind":"fact","content":"修改后的一句话"}],"forget":["要删除的旧记忆原文"]}
        规则：闲聊客套不记；add 最多 2 条；信息没变化就输出 {"add":[],"update":[],"forget":[]}；禁止编造；content 一句话不超过 60 字。
        """
        let user = "已知记忆：\n\(existingText)\n\n本轮对话：\n用户说：\(String(lastUser.prefix(500)))\n宠物回复：\(String(lastAnswer.prefix(400)))"
        guard let answer = try? await LiteLLM.complete(system: system, user: user, config: config, maxTokens: 400) else { return }
        guard let start = answer.firstIndex(of: "{"), let end = answer.lastIndex(of: "}"), start < end,
              let data = answer[start...end].data(using: .utf8),
              let diff = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        // update：原地改；forget：直接删（本地存储不需要 superseded 软删链）
        var items = loadAll()
        let existingTexts = Set(items.map { $0.fact })
        func indexOfOld(_ old: String) -> Int? {
            let o = old.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !o.isEmpty else { return nil }
            return items.firstIndex { $0.fact == o || $0.fact.hasPrefix(o) || o.hasPrefix($0.fact) }
        }
        for item in diff["update"] as? [[String: Any]] ?? [] {
            guard let old = item["old"] as? String, let content = item["content"] as? String else { continue }
            if let idx = indexOfOld(old), content.count >= 4, content.count <= 180, !existingTexts.contains(content) {
                items[idx].fact = content
                if let k = item["kind"] as? String { items[idx].kind = k }
            }
        }
        for old in diff["forget"] as? [String] ?? [] {
            if let idx = indexOfOld(old) {
                items.remove(at: idx)
            }
        }
        persist(items)
        // add：走 remember 的去重/长度/上限逻辑
        let adds = (diff["add"] as? [[String: Any]] ?? []).compactMap { $0["content"] as? String }
        if !adds.isEmpty { remember(adds) }
    }
}

/// 单轮轻量 LLM 调用（无工具、无历史）：记忆提取等辅助任务专用。
/// 与 AgentEngine.callLLM 同一配置通道（OpenAI 兼容 /chat/completions）。
enum LiteLLM {
    static func complete(system: String, user: String, config: AgentConfig,
                         maxTokens: Int = 150) async throws -> String {
        var body: [String: Any] = [
            "model": config.model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
            "temperature": 0.2,
            "max_tokens": maxTokens,
        ]
        // GLM 系默认思考模式会把 token 上限整个吃光 → 记忆提取永远空转，
        // 必须显式关掉（与 AgentEngine 主通道同规则：glm 前缀才注入）
        if config.model.lowercased().hasPrefix("glm") {
            body["thinking"] = ["type": "disabled"]
        }
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
