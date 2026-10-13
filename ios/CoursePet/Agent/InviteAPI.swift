// MARK: - 邀请码管理网络层（仅管理员可见）
// 后端 /auth/invite 三个端点的 Swift 封装：生成 / 列出 / 吊销。
// 任何调用方都假定当前用户是管理员（UI 层做权限判断，调用前 self-check AuthStore.load().isAdmin）
// 失败一律抛 AuthAPIError.serverMessage(detail)，沿用 AuthAPI 的错误格式。
import Foundation

struct InviteInfo: Codable, Identifiable {
    let id: Int
    let code: String
    let note: String
    let max_uses: Int
    let used_count: Int
    let expires_at: String?     // ISO8601 字符串，nil = 永不过期
    let disabled: Bool
}

enum InviteAPI {

    @MainActor
    static func list(baseURL: String) async throws -> [InviteInfo] {
        let url = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines) + "/auth/invite")!
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 15
        guard let token = AuthStore.load()?.accessToken, !token.isEmpty else {
            throw AuthAPIError.serverMessage("未登录")
        }
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw AuthAPIError.invalidResponse }
        guard http.statusCode == 200 else {
            if let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let d = j["detail"] as? String { throw AuthAPIError.serverMessage(d) }
            throw AuthAPIError.serverMessage("列出邀请码失败(\(http.statusCode))")
        }
        struct Out: Codable { let invites: [InviteInfo] }
        return (try JSONDecoder().decode(Out.self, from: data)).invites
    }

    @MainActor
    static func create(baseURL: String, note: String, maxUses: Int, expiresDays: Int) async throws -> InviteInfo {
        let url = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines) + "/auth/invite")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guard let token = AuthStore.load()?.accessToken, !token.isEmpty else {
            throw AuthAPIError.serverMessage("未登录")
        }
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = [
            "note": note,
            "max_uses": maxUses,
            "expires_days": expiresDays,
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw AuthAPIError.invalidResponse }
        guard http.statusCode == 200 else {
            if let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let d = j["detail"] as? String { throw AuthAPIError.serverMessage(d) }
            throw AuthAPIError.serverMessage("生成邀请码失败(\(http.statusCode))")
        }
        return try JSONDecoder().decode(InviteInfo.self, from: data)
    }

    @MainActor
    static func revoke(baseURL: String, id: Int) async throws {
        let url = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines) + "/auth/invite/\(id)")!
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        req.timeoutInterval = 15
        guard let token = AuthStore.load()?.accessToken, !token.isEmpty else {
            throw AuthAPIError.serverMessage("未登录")
        }
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw AuthAPIError.invalidResponse }
        guard http.statusCode == 200 else {
            if let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let d = j["detail"] as? String { throw AuthAPIError.serverMessage(d) }
            throw AuthAPIError.serverMessage("吊销失败(\(http.statusCode))")
        }
    }
}
