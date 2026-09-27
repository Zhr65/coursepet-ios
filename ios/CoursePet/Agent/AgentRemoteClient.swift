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
        return decoded.messages.compactMap { mapMessage(kind: $0.kind, text: $0.text) }
    }

    // MARK: 流式对话（NDJSON）：服务器每产生一条展示消息就推一行 JSON，边收边渲染
    // 多轮工具调用时过程标签即时上屏，等待不再是"一整块空白"。
    // 旧版服务器没有 /agent/chat/stream（404）→ 自动回落一次性 chat()。
    static func chatStream(baseURL: String, username: String, password: String,
                           message: String) -> AsyncThrowingStream<ChatDisplayMessage, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    var token = try await ensureToken(baseURL: baseURL, username: username, password: password)
                    var request = makeRequest(baseURL: baseURL, path: "/agent/chat/stream",
                                              token: token, body: ["message": message])
                    var (bytes, response) = try await URLSession.shared.bytes(for: request)

                    // token 失效：重新登录再试一次
                    if (response as? HTTPURLResponse)?.statusCode == 401 {
                        cachedToken = nil
                        tokenFingerprint = nil
                        token = try await ensureToken(baseURL: baseURL, username: username, password: password)
                        request = makeRequest(baseURL: baseURL, path: "/agent/chat/stream",
                                              token: token, body: ["message": message])
                        (bytes, response) = try await URLSession.shared.bytes(for: request)
                    }

                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    if status == 404 {
                        // 服务器版本较旧：回落非流式，一次性产出全部消息
                        let messages = try await chat(baseURL: baseURL, username: username,
                                                      password: password, message: message)
                        for msg in messages { continuation.yield(msg) }
                        continuation.finish()
                        return
                    }
                    guard status == 200 else { throw URLError(.badServerResponse) }

                    for try await line in bytes.lines {
                        guard let data = line.data(using: .utf8),
                              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                        else { continue }
                        if obj["done"] as? Bool == true { break }
                        guard let kind = obj["kind"] as? String,
                              let text = obj["text"] as? String else { continue }
                        if let msg = mapMessage(kind: kind, text: text) {
                            continuation.yield(msg)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // 服务器消息 → 界面消息（流式/非流式共用一份映射）
    private static func mapMessage(kind: String, text: String) -> ChatDisplayMessage? {
        switch kind {
        case "user":
            return nil  // 用户消息本地已先展示，跳过服务器回显避免重复
        case "assistant":
            // 推理模型的回答常带首尾空行，trim 后再上屏
            let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return ChatDisplayMessage(kind: .assistant, text: clean)
        case "tool_trace":
            return ChatDisplayMessage(kind: .toolTrace(text), text: text)
        case "error":
            return ChatDisplayMessage(kind: .error, text: text)
        default:
            return nil
        }
    }

    // MARK: 课表同步（数据同源：对话前把本地课表整表推给服务器，Agent 查库 = 手机数据）
    // 进程内指纹节流：课表无变化时零网络开销；加课/删课/改课自动重新同步。
    // 静默失败：同步不通不该挡住聊天，下次对话会再试。
    private static var lastCoursesFingerprint: String?

    static func syncCoursesIfNeeded(baseURL: String, username: String, password: String) async {
        let dm = DataManager.shared
        // 空课表不上推：避免 OCR 还没导入就把服务器上已有的课表清空
        guard !dm.courses.isEmpty else { return }
        let fingerprint = dm.courses
            .map { "\($0.id)|\($0.name)|\($0.teacher)|\($0.location)|\($0.dayOfWeek)|\($0.startTime)|\($0.endTime)|\($0.weekParity.rawValue)" }
            .sorted()
            .joined(separator: ";") + "#\(dm.semesterStartDate)"
        guard fingerprint != lastCoursesFingerprint else { return }

        do {
            let token = try await ensureToken(baseURL: baseURL, username: username, password: password)
            let courses: [[String: Any]] = dm.courses.map { c in
                [
                    "name": c.name,
                    "teacher": c.teacher,
                    "location": c.location,
                    "day_of_week": c.dayOfWeek,
                    "start_time": c.startTime,
                    "end_time": c.endTime,
                    // iOS 的 .both 与服务器端的 "all" 是同一语义，映射后再传
                    "week_parity": c.weekParity == .both ? "all" : c.weekParity.rawValue,
                ]
            }
            var body: [String: Any] = ["courses": courses]
            if !dm.semesterStartDate.isEmpty { body["semester_start_date"] = dm.semesterStartDate }
            let (_, response) = try await post(baseURL: baseURL, path: "/sync/courses", token: token, body: body)
            if (response as? HTTPURLResponse)?.statusCode == 200 {
                lastCoursesFingerprint = fingerprint
            }
        } catch {
            // 静默：服务器模式不因同步失败而不可用
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
        let request = makeRequest(baseURL: baseURL, path: path, token: token, body: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, response)
    }

    // 请求构造（普通 POST 与流式 bytes 共用）
    private static func makeRequest(baseURL: String, path: String, token: String?,
                                    body: [String: Any]?) -> URLRequest {
        var request = URLRequest(url: URL(string: trimmedBase(baseURL) + path)!)
        request.httpMethod = "POST"
        request.timeoutInterval = 120  // ReAct 多轮 + 推理模型，给足时间
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body { request.httpBody = try? JSONSerialization.data(withJSONObject: body) }
        return request
    }

    private static func trimmedBase(_ url: String) -> String {
        var base = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.hasSuffix("/") { base.removeLast() }
        return base
    }
}
