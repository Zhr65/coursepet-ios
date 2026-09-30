// MARK: - 兴趣动态（Muse 式"它知道你喜欢什么，主动推给你看"）
// 内容生成：取长期记忆里的兴趣事实 → LLM 生成一条趣味分享（历史/科技/学习方法…）；
// 点赞/点踩写回记忆，下次生成时模型自己避开踩过的、多推赞过的——越用越懂你。
// 通道：服务器模式走 POST /agent/discover（记忆表在服务端）；端侧模式直连 LLM。
import SwiftUI

struct DiscoverPost: Codable, Identifiable {
    let id: UUID
    var date: Date
    var topic: String
    var title: String
    var body: String
    var liked: Bool?   // nil=未评 true=赞 false=踩
}

enum DiscoverStore {
    private static let maxPosts = 20
    private static var cache: [DiscoverPost]?

    private static var fileURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("agent_discover.json")
    }

    static func loadAll() -> [DiscoverPost] {
        if let cache { return cache }
        guard let data = try? Data(contentsOf: fileURL),
              let items = try? JSONDecoder().decode([DiscoverPost].self, from: data) else {
            cache = []
            return []
        }
        cache = items
        return items
    }

    static func append(_ post: DiscoverPost) {
        var posts = loadAll()
        posts.insert(post, at: 0)
        if posts.count > maxPosts { posts = Array(posts.prefix(maxPosts)) }
        persist(posts)
    }

    static func mark(id: UUID, liked: Bool) {
        var posts = loadAll()
        if let idx = posts.firstIndex(where: { $0.id == id }) {
            posts[idx].liked = liked
        }
        persist(posts)
    }

    private static func persist(_ posts: [DiscoverPost]) {
        cache = posts
        if let data = try? JSONEncoder().encode(posts) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}

enum DiscoverError: LocalizedError {
    case notConfigured
    case badResponse
    var errorDescription: String? {
        switch self {
        case .notConfigured: return "先在设置里配好 AI 管家（端侧 Key 或服务器账号）才能生成动态"
        case .badResponse: return "这条没生成好，再试一次？"
        }
    }
}

enum DiscoverEngine {
    /// 生成提示词（两端共用）：兴趣记忆做选题，输出紧凑 JSON
    private static let systemPrompt = """
    你是校园宠物管家的兴趣分享引擎。根据用户的兴趣记忆挑一个话题，写一条学生爱看的趣味分享
    （历史冷知识/科技资讯/学习方法/校园生活等，选用户最可能有兴趣的方向）。
    只输出一个 JSON 对象，不要输出任何其他内容，格式：
    {"topic":"兴趣标签2-6字","title":"一句话标题(20字内)","body":"正文80-150字，口语化、有趣，结尾带一个互动小问题"}
    """

    private static func userPrompt(facts: [String], seenTopics: [String]) -> String {
        let factText = facts.isEmpty ? "（暂无记忆，从大学生普遍兴趣里挑：学习方法/历史冷知识/科技资讯/校园生活）"
                                     : facts.joined(separator: "\n")
        let seen = seenTopics.isEmpty ? "（无）" : seenTopics.joined(separator: "、")
        return "用户兴趣记忆：\n\(factText)\n\n最近已推过的话题（避免重复）：\(seen)"
    }

    /// 生成一条：服务器配置了走服务器（记忆表在服务端），否则走端侧直连
    static func generateNext() async throws -> DiscoverPost {
        let server = AgentConfigStore.loadServerConfig()
        if server.isConfigured {
            return try await generateViaServer(server)
        }
        let config = AgentConfigStore.load()
        guard config.isConfigured else { throw DiscoverError.notConfigured }
        return try await generateOnDevice(config)
    }

    /// 拉今天 scheduler 预生成的动态（服务器模式专属；没有/失败返回 nil，客户端再实时生成）
    static func fetchTodayPrefetched() async -> DiscoverPost? {
        let server = AgentConfigStore.loadServerConfig()
        guard server.isConfigured,
              let token = try? await AgentRemoteClient.ensureToken(
                  baseURL: server.baseURL, username: server.username, password: server.password),
              let url = URL(string: AgentRemoteClient.trimmedBase(server.baseURL) + "/agent/discover/today") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let item = obj["item"] as? [String: Any],
              let topic = item["topic"] as? String,
              let title = item["title"] as? String,
              let body = item["body"] as? String else { return nil }
        return DiscoverPost(id: UUID(), date: Date(),
                            topic: String(topic.prefix(8)), title: String(title.prefix(30)),
                            body: String(body.prefix(300)), liked: nil)
    }

    private static func parsePost(_ raw: String) throws -> DiscoverPost {
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"),
              start < end,
              let data = raw[start...end].data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let topic = obj["topic"] as? String,
              let title = obj["title"] as? String,
              let body = obj["body"] as? String,
              !topic.isEmpty, !title.isEmpty, !body.isEmpty else {
            throw DiscoverError.badResponse
        }
        return DiscoverPost(id: UUID(), date: Date(),
                            topic: String(topic.prefix(8)),
                            title: String(title.prefix(30)),
                            body: String(body.prefix(300)),
                            liked: nil)
    }

    private static func generateOnDevice(_ config: AgentConfig) async throws -> DiscoverPost {
        let facts = AgentMemoryStore.topFacts(query: "兴趣爱好 喜欢关注", limit: 10)
        let seen = DiscoverStore.loadAll().prefix(8).map { $0.topic }
        let raw = try await LiteLLM.complete(system: systemPrompt,
                                             user: userPrompt(facts: facts, seenTopics: seen),
                                             config: config, maxTokens: 600)
        return try parsePost(raw)
    }

    private static func generateViaServer(_ server: AgentConfigStore.ServerConfig) async throws -> DiscoverPost {
        guard let token = try? await AgentRemoteClient.ensureToken(
            baseURL: server.baseURL, username: server.username, password: server.password) else {
            throw DiscoverError.notConfigured
        }
        guard let url = URL(string: AgentRemoteClient.trimmedBase(server.baseURL) + "/agent/discover") else {
            throw DiscoverError.badResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw DiscoverError.badResponse }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let topic = obj["topic"] as? String,
              let title = obj["title"] as? String,
              let body = obj["body"] as? String else { throw DiscoverError.badResponse }
        return DiscoverPost(id: UUID(), date: Date(),
                            topic: String(topic.prefix(8)), title: String(title.prefix(30)),
                            body: String(body.prefix(300)), liked: nil)
    }

    /// 点赞/点踩反馈：端侧写记忆；服务器模式调接口写服务端记忆表（下次生成自动生效）
    static func sendFeedback(topic: String, liked: Bool) async {
        let server = AgentConfigStore.loadServerConfig()
        if server.isConfigured {
            guard let token = try? await AgentRemoteClient.ensureToken(
                baseURL: server.baseURL, username: server.username, password: server.password),
                  let url = URL(string: AgentRemoteClient.trimmedBase(server.baseURL) + "/agent/discover/feedback") else { return }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 30
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(
                withJSONObject: ["topic": topic, "liked": liked])
            _ = try? await URLSession.shared.data(for: request)
        } else {
            let fact = liked ? "用户对「\(topic)」内容感兴趣（点赞了相关分享）"
                             : "用户对「\(topic)」推送不感兴趣（点踩）"
            AgentMemoryStore.remember([fact])
        }
    }
}

// MARK: - 动态板块页（聊天页"更多"菜单入口）
struct DiscoverView: View {
    @State private var posts: [DiscoverPost] = []
    @State private var isGenerating = false
    @State private var errorText = ""

    init() { }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("它根据你的兴趣记忆主动挑的内容——点赞就多推，点踩就避开")
                    .font(.caption)
                    .foregroundColor(.secondary)

                if let current = posts.first {
                    card(current)
                } else if !isGenerating {
                    emptyState
                }

                if isGenerating {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("正在琢磨给你看点什么…")
                            .font(.footnote).foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                }

                if !errorText.isEmpty {
                    Text(errorText)
                        .font(.caption).foregroundColor(.red)
                }

                // 点评过的历史（最近 6 条）
                let judged = posts.filter { $0.liked != nil }.prefix(6)
                if !judged.isEmpty {
                    Text("你的反馈").font(.footnote).fontWeight(.semibold)
                        .foregroundColor(.secondary).padding(.top, 6)
                    ForEach(Array(judged)) { post in
                        HStack(spacing: 8) {
                            Image(systemName: post.liked == true ? "hand.thumbsup.fill" : "hand.thumbsdown.fill")
                                .font(.caption)
                                .foregroundColor(post.liked == true ? .green : .gray)
                            Text(post.title)
                                .font(.caption).foregroundColor(.primary).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("兴趣动态")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    Task { await generate() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(isGenerating)
            }
        }
        .onAppear {
            posts = DiscoverStore.loadAll()
            // 每天第一条自动备好（Muse 式"打开即见"）：优先拉服务器预生成，没有再实时生成；
            // UserDefaults 按日门闩，一天只自动走一次，手动"换一条"不受限
            if !posts.contains(where: { Calendar.current.isDateInToday($0.date) }),
               !isGenerating,
               !UserDefaults.standard.bool(forKey: "discover.autoGen.\(Self.todayKey())") {
                Task { await autoGenerateToday() }
            }
        }
    }

    private static func todayKey() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyyMMdd"
        return f.string(from: Date())
    }

    /// 每日自动获取今天第一条：预生成优先，实时生成兜底；成功才置门闩，失败下次再试
    private func autoGenerateToday() async {
        let key = "discover.autoGen.\(Self.todayKey())"
        if let prefetched = await DiscoverEngine.fetchTodayPrefetched() {
            UserDefaults.standard.set(true, forKey: key)
            DiscoverStore.append(prefetched)
            posts = DiscoverStore.loadAll()
            return
        }
        if await generate() {
            UserDefaults.standard.set(true, forKey: key)
        }
    }

    // MARK: 当前一条卡片
    private func card(_ post: DiscoverPost) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(post.topic)
                    .font(.caption).fontWeight(.semibold)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(Color.indigo.opacity(0.14)))
                    .foregroundColor(.indigo)
                Spacer(minLength: 0)
                Text(timeText(post.date))
                    .font(.caption2).foregroundColor(Color(.tertiaryLabel))
            }
            Text(post.title)
                .font(.headline)
                .foregroundColor(.primary)
            Text(post.body)
                .font(.subheadline)
                .foregroundColor(.primary.opacity(0.85))
                .lineSpacing(3)
            // 点赞/点踩 + 换一条（Muse 式反馈闭环）
            HStack(spacing: 18) {
                Button {
                    judge(post, liked: true)
                } label: {
                    Label("喜欢", systemImage: post.liked == true ? "hand.thumbsup.fill" : "hand.thumbsup")
                        .font(.footnote)
                        .foregroundColor(post.liked == true ? .green : .secondary)
                }
                Button {
                    judge(post, liked: false)
                } label: {
                    Label("不感兴趣", systemImage: post.liked == false ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                        .font(.footnote)
                        .foregroundColor(post.liked == false ? .red : .secondary)
                }
                Spacer(minLength: 0)
                Button {
                    Task { await generate() }
                } label: {
                    Label("换一条", systemImage: "arrow.clockwise")
                        .font(.footnote).fontWeight(.medium)
                }
                .disabled(isGenerating)
            }
            .padding(.top, 2)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemGroupedBackground)))
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Text("✨").font(.largeTitle)
            Text("还没有动态").font(.footnote).foregroundColor(.secondary)
            Button {
                Task { await generate() }
            } label: {
                Text("生成第一条")
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    // MARK: 动作
    private func judge(_ post: DiscoverPost, liked: Bool) {
        DiscoverStore.mark(id: post.id, liked: liked)
        posts = DiscoverStore.loadAll()
        Task { await DiscoverEngine.sendFeedback(topic: post.topic, liked: liked) }
    }

    /// 生成一条并落库；返回是否成功（调用方可据此决定是否置"今天已生成"门闩）
    @discardableResult
    private func generate() async -> Bool {
        isGenerating = true
        errorText = ""
        defer { isGenerating = false }
        do {
            let post = try await DiscoverEngine.generateNext()
            DiscoverStore.append(post)
            posts = DiscoverStore.loadAll()
            return true
        } catch {
            errorText = error.localizedDescription
            return false
        }
    }

    private func timeText(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "M/d HH:mm"
        return f.string(from: date)
    }
}
