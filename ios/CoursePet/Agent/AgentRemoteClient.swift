// MARK: - V2 服务器模式客户端
// 把对话请求转发到自建 FastAPI 后端（ReAct 循环在服务器执行）：
//   登录拿 JWT → POST /agent/chat → 返回完整过程消息（过程标签 + 最终回答）
// 与端侧引擎的关系：二选一——设置页填了服务器配置就启用这里，留空走端侧 Agent。
// 面试讲述点：同一套 ReAct 逻辑的两种部署形态（端侧 BYOK / 服务端集中管理）。
import Foundation

enum AgentRemoteClient {

    // token 内存缓存（进程内复用；换服务器/账号自动失效，401 时重新登录）
    private static var cachedToken: String?
    private static var tokenFingerprint: String?

    // MARK: 服务器返回的消息结构（与 schemas.py 的 DisplayMessage 对齐）
    private struct ChatResponse: Decodable {
        struct Item: Decodable {
            let kind: String   // user / assistant / tool_trace / error
            let text: String
        }
        let messages: [Item]
    }

    private struct TokenResponse: Decodable {
        let accessToken: String
        enum CodingKeys: String, CodingKey { case accessToken = "access_token" }
    }

    // MARK: 对话（核心入口）——返回除 user 外的全部展示消息
    static func chat(baseURL: String, username: String, password: String,
                     message: String) async throws -> [ChatDisplayMessage] {
        let token = try await ensureToken(baseURL: baseURL, username: username, password: password)
        var (data, response) = try await post(baseURL: baseURL, path: "/agent/chat",
                                              token: token, body: ["message": message])

        // token 失效：清缓存重新登录再试一次（服务器重启换密钥等场景）
        if (response as? HTTPURLResponse)?.statusCode == 401 {
            cachedToken = nil
            tokenFingerprint = nil
            let fresh = try await ensureToken(baseURL: baseURL, username: username, password: password)
            (data, response) = try await post(baseURL: baseURL, path: "/agent/chat",
                                              token: fresh, body: ["message": message])
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }

        let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        return decoded.messages.compactMap { item -> ChatDisplayMessage? in
            switch item.kind {
            case "user":
                return nil  // 用户消息本地已先展示，跳过服务器回显避免重复
            case "assistant":
                // 推理模型的回答常带首尾空行，trim 后再上屏
                let clean = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
                return ChatDisplayMessage(kind: .assistant, text: clean)
            case "tool_trace":
                return ChatDisplayMessage(kind: .toolTrace(item.text), text: item.text)
            case "error":
                return ChatDisplayMessage(kind: .error, text: item.text)
            default:
                return nil
            }
        }
    }

    // MARK: 清空服务器端对话历史（"新对话"按钮；fire-and-forget）
    static func clearHistory(baseURL: String, username: String, password: String) async {
        guard let token = try? await ensureToken(baseURL: baseURL, username: username, password: password),
              let url = URL(string: trimmedBase(baseURL) + "/agent/history") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        _ = try? await URLSession.shared.data(for: request)
    }

    // MARK: 登录拿 token（登录 401 时自动注册，首次使用零操作）
    private static func ensureToken(baseURL: String, username: String,
                                    password: String) async throws -> String {
        let fingerprint = "\(baseURL)|\(username)|\(password)"
        if let cached = cachedToken, tokenFingerprint == fingerprint { return cached }

        // 1) 尝试登录
        let (loginData, loginHTTP) = try await post(baseURL: baseURL, path: "/auth/login",
                                                    token: nil, body: ["username": username, "password": password])
        if (loginHTTP as? HTTPURLResponse)?.statusCode == 200 {
            let token = try JSONDecoder().decode(TokenResponse.self, from: loginData).accessToken
            cachedToken = token
            tokenFingerprint = fingerprint
            return token
        }

        // 2) 登录失败 → 自动注册（首次在该服务器使用此用户名）
        let (regData, regHTTP) = try await post(
            baseURL: baseURL, path: "/auth/register", token: nil,
            body: ["username": username, "password": password, "pet_name": DataManager.shared.petName])
        if (regHTTP as? HTTPURLResponse)?.statusCode == 200 {
            let token = try JSONDecoder().decode(TokenResponse.self, from: regData).accessToken
            cachedToken = token
            tokenFingerprint = fingerprint
            return token
        }

        // 注册也失败：多为"用户名已被占用但密码不对"
        if let root = try? JSONSerialization.jsonObject(with: regData) as? [String: Any],
           let detail = root["detail"] as? String {
            throw NSError(domain: "CoursePetAgent", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: detail])
        }
        throw URLError(.badServerResponse)
    }

    // MARK: 通用 POST
    private static func post(baseURL: String, path: String, token: String?,
                             body: [String: Any]?) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: URL(string: trimmedBase(baseURL) + path)!)
        request.httpMethod = "POST"
        request.timeoutInterval = 120  // ReAct 多轮 + 推理模型，给足时间
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        return try await URLSession.shared.data(for: request)
    }

    private static func trimmedBase(_ url: String) -> String {
        var base = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.hasSuffix("/") { base.removeLast() }
        return base
    }
}
