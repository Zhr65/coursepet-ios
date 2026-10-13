// MARK: - 登录相关网络请求
// 独立于 AgentRemoteClient（对话专用），只管认证三件事：
//   /auth/apple-login   — Apple 登录
//   /auth/login          — 用户名密码登录
//   /auth/register       — 注册
//   /auth/refresh        — 自动续 Token
// 所有接口返回 AuthTokens，调用方存进 AuthKeychain。
import Foundation

enum AuthAPIError: LocalizedError {
    case invalidResponse
    case serverMessage(String)
    case network(Error)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "服务器返回异常"
        case .serverMessage(let s): return s
        case .network(let e): return e.localizedDescription
        }
    }
}

enum AuthAPI {

    // MARK: - Apple 登录

    @MainActor
    static func appleLogin(baseURL: String, credential: AppleCredential) async throws -> AuthTokens {
        let url = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines) + "/auth/apple-login")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["identity_token": credential.identityToken]
        if let given = credential.givenName { body["given_name"] = given }
        if let family = credential.familyName { body["family_name"] = family }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return try await _decodeTokens(from: request)
    }

    // MARK: - 用户名密码登录

    @MainActor
    static func passwordLogin(baseURL: String, username: String, password: String) async throws -> AuthTokens {
        let url = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines) + "/auth/login")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["username": username, "password": password])
        return try await _decodeTokens(from: request)
    }

    // MARK: - 注册

    /// 注册。invite = 邀请码：服务端 REGISTER_OPEN=false（默认）时必填，否则会返回 403。
    @MainActor
    static func register(baseURL: String, username: String, password: String,
                         petName: String = "小狼", invite: String = "") async throws -> AuthTokens {
        let url = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines) + "/auth/register")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["username": username, "password": password, "pet_name": petName]
        let code = invite.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if !code.isEmpty { body["invite"] = code }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return try await _decodeTokens(from: request)
    }

    // MARK: - Private

    /// 统一解码后端返回的 TokenOut（字段是 snake_case，手动映射到 AuthTokens）
    private static func _decodeTokens(from request: URLRequest) async throws -> AuthTokens {
        var req = request
        req.timeoutInterval = 15   // 默认 60s 太长：服务器够不着时用户干等转圈
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw AuthAPIError.invalidResponse }
        guard http.statusCode == 200 else {
            // 尝试解码后端错误消息 {"detail": "..."}
            if let errJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let detail = errJson["detail"] as? String {
                throw AuthAPIError.serverMessage(detail)
            }
            if http.statusCode == 403 {
                // 403 多为网关/防火墙拦截（阿里云未备案域名拦截特征是 403）。
                // 不在这里硬编码个人服务器 IP —— 1) 别人用会指向你的服务器
                // 2) 你换服务器后这段会过时。让用户回到设置页自己改地址。
                let trimmedBase = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
                let hint = trimmedBase.isEmpty
                    ? "请到设置页填服务器地址"
                    : "请到设置页核对服务器地址（\(trimmedBase)）"
                throw AuthAPIError.serverMessage("服务器连不上（403，域名可能被云服务商拦截），\(hint)")
            }
            throw AuthAPIError.serverMessage("登录失败（\(http.statusCode)）")
        }
        struct Raw: Codable {
            let access_token: String
            let refresh_token: String?
            let pet_name: String
            let login_method: String?
            let is_admin: Bool?
        }
        let raw = try JSONDecoder().decode(Raw.self, from: data)
        return AuthTokens(
            accessToken: raw.access_token,
            refreshToken: raw.refresh_token ?? "",
            petName: raw.pet_name,
            loginMethod: raw.login_method ?? "password",
            isAdmin: raw.is_admin ?? false
        )
    }
}
