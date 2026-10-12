// MARK: - 邀请码管理客户端（AI 管家 · 服务器模式）
// 复用 AgentRemoteClient 的 token 缓存/续期链路（ensureToken + 401 重试），
// 与 AgentLibraryClient 同一套路。对应后端 app/main.py 三个接口：
//   GET    /auth/invite          列出我生成的码
//   POST   /auth/invite          铸新码（备注 / 可用人数 / 有效天数）
//   DELETE /auth/invite/{id}     吊销（软删除：置 disabled，保留记录）
// 目的：把「发码」从「SSH 上服务器跑 ops/make_invite.py」搬进 App 内。
import Foundation

/// 单条邀请码（字段对齐后端 main.py 的 _invite_out）
struct InviteItem: Identifiable, Codable, Equatable {
    let id: Int
    var code: String
    var note: String
    var maxUses: Int
    var usedCount: Int
    var expiresAt: String?      // UTC ISO 字符串；nil = 永不过期
    var disabled: Bool

    enum CodingKeys: String, CodingKey {
        case id, code, note, disabled
        case maxUses = "max_uses"
        case usedCount = "used_count"
        case expiresAt = "expires_at"
    }

    /// 是否还能用来注册
    var isUsable: Bool { !disabled && !isExhausted && !isExpired }
    var isExhausted: Bool { usedCount >= maxUses }
    var isExpired: Bool {
        guard let expiresAt, let d = InviteItem.parseUTC(expiresAt) else { return false }
        return d < Date()
    }

    var statusText: String {
        if disabled { return "已吊销" }
        if isExpired { return "已过期" }
        if isExhausted { return "已用完" }
        return "有效"
    }

    /// 后端存的是 naive UTC（datetime.utcnow），故按 UTC 解析
    static func parseUTC(_ iso: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f.date(from: String(iso.prefix(19)))
    }
}

enum AgentInviteClient {

    // MARK: - 列表
    static func list(baseURL: String, username: String, password: String) async throws -> [InviteItem] {
        let (data, status) = try await send(method: "GET", baseURL: baseURL,
                                            path: "/auth/invite",
                                            username: username, password: password)
        guard status == 200 else { throw serverError(data, status) }
        struct Resp: Decodable { let invites: [InviteItem] }
        return try JSONDecoder().decode(Resp.self, from: data).invites
    }

    // MARK: - 铸码
    static func create(baseURL: String, username: String, password: String,
                       note: String, maxUses: Int, expiresDays: Int) async throws -> InviteItem {
        let body: [String: Any] = ["note": note, "max_uses": maxUses, "expires_days": expiresDays]
        let (data, status) = try await send(method: "POST", baseURL: baseURL,
                                            path: "/auth/invite",
                                            username: username, password: password, body: body)
        guard status == 200 else { throw serverError(data, status) }
        return try JSONDecoder().decode(InviteItem.self, from: data)
    }

    // MARK: - 吊销
    static func revoke(baseURL: String, username: String, password: String, id: Int) async throws {
        let (data, status) = try await send(method: "DELETE", baseURL: baseURL,
                                            path: "/auth/invite/\(id)",
                                            username: username, password: password)
        guard status == 200 else { throw serverError(data, status) }
    }

    // MARK: - Private

    /// 统一执行：拿 token → 发请求 → 遇 401 清缓存强刷再试一次
    private static func send(method: String, baseURL: String, path: String,
                             username: String, password: String,
                             body: [String: Any]? = nil) async throws -> (Data, Int) {
        let token = try await AgentRemoteClient.ensureToken(baseURL: baseURL,
                                                            username: username, password: password)
        var request = build(method: method, baseURL: baseURL, path: path, token: token, body: body)
        var (data, resp) = try await URLSession.shared.data(for: request)
        if (resp as? HTTPURLResponse)?.statusCode == 401 {
            AgentRemoteClient.invalidateCachedToken()
            let fresh = try await AgentRemoteClient.ensureToken(baseURL: baseURL, username: username,
                                                                password: password, forceRefresh: true)
            request = build(method: method, baseURL: baseURL, path: path, token: fresh, body: body)
            (data, resp) = try await URLSession.shared.data(for: request)
        }
        return (data, (resp as? HTTPURLResponse)?.statusCode ?? 0)
    }

    private static func build(method: String, baseURL: String, path: String,
                              token: String, body: [String: Any]?) -> URLRequest {
        var request = URLRequest(url: URL(string: AgentRemoteClient.trimmedBase(baseURL) + path)!)
        request.httpMethod = method
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body { request.httpBody = try? JSONSerialization.data(withJSONObject: body) }
        return request
    }

    private static func serverError(_ data: Data, _ status: Int) -> Error {
        let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["detail"] as? String
        return NSError(domain: "CoursePetInvite", code: status,
                       userInfo: [NSLocalizedDescriptionKey: detail ?? "服务器返回 \(status)"])
    }
}
