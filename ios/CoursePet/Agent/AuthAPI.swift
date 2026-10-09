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

    @MainActor
    static func register(baseURL: String, username: String, password: String, petName: String = "小狼") async throws -> AuthTokens {
        let url = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines) + "/auth/register")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "username": username, "password": password, "pet_name": petName
        ])
        return try await _decodeTokens(from: request)
    }

    // MARK: - Private

    /// 统一解码后端返回的 TokenOut（字段是 snake_case，手动映射到 AuthTokens）
    private static func _decodeTokens(from request: URLRequest) async throws -> AuthTokens {
        let (data, resp) = try await URLSession.shared.data(for: request)
        guard let http = resp as? HTTPURLResponse else { throw AuthAPIError.invalidResponse }
        guard http.statusCode == 200 else {
            // 尝试解码后端错误消息 {"detail": "..."}
            if let errJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let detail = errJson["detail"] as? String {
                throw AuthAPIError.serverMessage(detail)
            }
            throw AuthAPIError.serverMessage("登录失败（\(http.statusCode)）")
        }
        struct Raw: Codable {
            let access_token: String
            let refresh_token: String?
            let pet_name: String
            let login_method: String?
        }
        let raw = try JSONDecoder().decode(Raw.self, from: data)
        return AuthTokens(
            accessToken: raw.access_token,
            refreshToken: raw.refresh_token ?? "",
            petName: raw.pet_name,
            loginMethod: raw.login_method ?? "password"
        )
    }
}
