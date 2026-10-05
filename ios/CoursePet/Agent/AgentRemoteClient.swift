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
    /// 对话请求体：message + 可选 base64 图片（拍照多模态）+ 可选今天系统日历文本
    private static func chatBody(message: String, image: String?,
                                 calendarContext: String? = nil) -> [String: Any] {
        var body: [String: Any] = ["message": message]
        if let img = image, !img.isEmpty { body["images"] = [img] }
        if let cal = calendarContext, !cal.isEmpty { body["calendar_context"] = cal }
        return body
    }

    static func chat(baseURL: String, username: String, password: String,
                     message: String, image: String? = nil,
                     calendarContext: String? = nil) async throws -> [ChatDisplayMessage] {
        let token = try await ensureToken(baseURL: baseURL, username: username, password: password)
        var (data, response) = try await post(baseURL: baseURL, path: "/agent/chat",
                                              token: token,
                                              body: chatBody(message: message, image: image,
                                                             calendarContext: calendarContext))

        // token 失效：清缓存重新登录再试一次（服务器重启换密钥等场景）
        if (response as? HTTPURLResponse)?.statusCode == 401 {
            cachedToken = nil
            tokenFingerprint = nil
            let fresh = try await ensureToken(baseURL: baseURL, username: username, password: password)
            (data, response) = try await post(baseURL: baseURL, path: "/agent/chat",
                                              token: fresh,
                                              body: chatBody(message: message, image: image,
                                                             calendarContext: calendarContext))
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
                           message: String, image: String? = nil,
                           calendarContext: String? = nil) -> AsyncThrowingStream<ChatDisplayMessage, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    var token = try await ensureToken(baseURL: baseURL, username: username, password: password)
                    var request = makeRequest(baseURL: baseURL, path: "/agent/chat/stream",
                                              token: token,
                                              body: chatBody(message: message, image: image,
                                                             calendarContext: calendarContext))
                    var (bytes, response) = try await URLSession.shared.bytes(for: request)

                    // token 失效：重新登录再试一次
                    if (response as? HTTPURLResponse)?.statusCode == 401 {
                        cachedToken = nil
                        tokenFingerprint = nil
                        token = try await ensureToken(baseURL: baseURL, username: username, password: password)
                        request = makeRequest(baseURL: baseURL, path: "/agent/chat/stream",
                                              token: token,
                                              body: chatBody(message: message, image: image,
                                                             calendarContext: calendarContext))
                        (bytes, response) = try await URLSession.shared.bytes(for: request)
                    }

                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    if status == 404 {
                        // 服务器版本较旧：回落非流式，一次性产出全部消息
                        let messages = try await chat(baseURL: baseURL, username: username,
                                                      password: password, message: message, image: image)
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
        case "card":
            // 模式 11：服务端 show_card 产出的卡片 JSON → 本地渲染；解析失败跳过不崩
            guard let card = AgentCard.parse(text) else { return nil }
            return ChatDisplayMessage(kind: .card(card), text: text)
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

    // MARK: SOUL.md 同步（灵魂文件双端一致）：App 内保存时推送，服务端注入 system prompt。
    // fire-and-forget：推送失败不挡编辑（下次保存会再推）。
    static func pushSoul(baseURL: String, username: String, password: String, content: String) async {
        guard let token = try? await ensureToken(baseURL: baseURL, username: username, password: password) else { return }
        _ = try? await post(baseURL: baseURL, path: "/agent/soul", token: token, body: ["content": content])
    }

    // MARK: AI 晨报（扩展点：主动关怀）—— GET /agent/daily-brief，服务端当日缓存
    // 免签名环境无 APNs：推送走"端侧拉取文案 → 本地通知重排"，见 NotificationManager.refreshAIBriefing
    static func fetchDailyBrief(baseURL: String, username: String,
                                password: String) async throws -> String {
        let token = try await ensureToken(baseURL: baseURL, username: username, password: password)
        var request = URLRequest(url: URL(string: trimmedBase(baseURL) + "/agent/daily-brief")!)
        request.timeoutInterval = 45  // 首次生成要调 LLM
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        var (data, response) = try await URLSession.shared.data(for: request)
        // token 失效：重新登录再试一次
        if (response as? HTTPURLResponse)?.statusCode == 401 {
            cachedToken = nil
            tokenFingerprint = nil
            let fresh = try await ensureToken(baseURL: baseURL, username: username, password: password)
            request.setValue("Bearer \(fresh)", forHTTPHeaderField: "Authorization")
            (data, response) = try await URLSession.shared.data(for: request)
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let brief = obj["brief"] as? String, !brief.isEmpty else {
            throw URLError(.badServerResponse)
        }
        return brief
    }

    // MARK: DDL 前夜建议（主动管家）—— POST /agent/ddl-advice：批量一次 LLM 生成，
    // 服务端按批次内容当日缓存。失败抛错由调用方静默——静态三级轰炸文案兜底。
    static func fetchDDLAdvice(baseURL: String, username: String, password: String,
                               homeworks: [[String: Any]]) async throws -> [String: String] {
        let token = try await ensureToken(baseURL: baseURL, username: username, password: password)
        var request = makeRequest(baseURL: baseURL, path: "/agent/ddl-advice",
                                  token: token, body: ["homeworks": homeworks])
        request.timeoutInterval = 45  // 批量生成要调 LLM
        var (data, response) = try await URLSession.shared.data(for: request)
        if (response as? HTTPURLResponse)?.statusCode == 401 {
            cachedToken = nil
            tokenFingerprint = nil
            let fresh = try await ensureToken(baseURL: baseURL, username: username, password: password)
            request = makeRequest(baseURL: baseURL, path: "/agent/ddl-advice",
                                  token: fresh, body: ["homeworks": homeworks])
            request.timeoutInterval = 45
            (data, response) = try await URLSession.shared.data(for: request)
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let advices = obj["advices"] as? [String: String] else {
            throw URLError(.badServerResponse)
        }
        return advices
    }


    // MARK: 每周学习周报（主动管家）—— POST /agent/weekly-brief：端侧推周度统计，
    // 服务端一次 LLM 生成宠物口吻周报（服务端当周唯一缓存）。失败抛错由调用方静默。
    static func fetchWeeklyBrief(baseURL: String, username: String, password: String,
                                 stats: [String: Any]) async throws -> String {
        let token = try await ensureToken(baseURL: baseURL, username: username, password: password)
        var request = makeRequest(baseURL: baseURL, path: "/agent/weekly-brief",
                                  token: token, body: ["stats": stats])
        request.timeoutInterval = 45  // 生成要调 LLM
        var (data, response) = try await URLSession.shared.data(for: request)
        if (response as? HTTPURLResponse)?.statusCode == 401 {
            cachedToken = nil
            tokenFingerprint = nil
            let fresh = try await ensureToken(baseURL: baseURL, username: username, password: password)
            request = makeRequest(baseURL: baseURL, path: "/agent/weekly-brief",
                                  token: fresh, body: ["stats": stats])
            request.timeoutInterval = 45
            (data, response) = try await URLSession.shared.data(for: request)
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let brief = obj["brief"] as? String, !brief.isEmpty else {
            throw URLError(.badServerResponse)
        }
        return brief
    }

    // MARK: 快递同步（扩展点：快递真追踪的数据同源）—— 与课程同步同套路
    // 整表上推（指纹节流）；响应里的合并结果若含服务器上 Agent 记的、手机端没有的
    // 快递（如聊天里发的取件短信），自动落回本地列表，双端收敛一致。
    private static var lastParcelsFingerprint: String?

    static func syncParcelsIfNeeded(baseURL: String, username: String, password: String) async {
        let dm = DataManager.shared
        let fingerprint = dm.parcels
            .map { "\($0.id)|\($0.code)|\($0.station)|\($0.trackingNumber ?? "")|\($0.pickedAt?.timeIntervalSince1970 ?? 0)" }
            .sorted()
            .joined(separator: ";")
        // 冷启动且本地无快递时不上推：避免覆盖服务器上还没同步下来的 Agent 记录
        guard fingerprint != lastParcelsFingerprint,
              !dm.parcels.isEmpty || lastParcelsFingerprint != nil else { return }
        do {
            let token = try await ensureToken(baseURL: baseURL, username: username, password: password)
            let parcels: [[String: Any]] = dm.parcels.map { p in
                var item: [String: Any] = [
                    "code": p.code,
                    "station": p.station,
                    "is_picked": p.pickedAt != nil,
                ]
                if let note = p.note { item["note"] = note }
                if let tracking = p.trackingNumber { item["tracking_number"] = tracking }
                return item
            }
            let (data, response) = try await post(baseURL: baseURL, path: "/sync/parcels",
                                                  token: token, body: ["parcels": parcels])
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let merged = obj["parcels"] as? [[String: Any]] else { return }
            lastParcelsFingerprint = fingerprint
            await MainActor.run {
                let existing = Set(dm.parcels.map { "\($0.code)|\($0.station)" })
                for item in merged {
                    guard let code = item["code"] as? String, !code.isEmpty else { continue }
                    let station = item["station"] as? String ?? ""
                    guard !existing.contains("\(code)|\(station)") else { continue }
                    // Agent 在服务器端记的快递 → 落回本地（addParcel 顺带触发取件提醒重建）
                    dm.addParcel(ParcelItem(
                        code: code,
                        station: station.isEmpty ? "未识别驿站" : station,
                        note: item["note"] as? String,
                        trackingNumber: item["tracking_number"] as? String
                    ))
                }
            }
        } catch {
            // 静默：同步失败不挡聊天，下次对话再试
        }
    }

    // MARK: 作业平台同步 —— 学习通端侧直连（手机网络出口，不受服务器机房 IP 风控影响），
    //  拉完本地合并 + push 服务器入库；智慧树仍由服务器轮询代拉。
    //  学习通凭据只存手机 Keychain（ChaoxingClient.Credentials），服务器不落密码。

    struct PlatformAccountStatus {
        let platform: String
        let username: String
        let status: String       // ok / auth_failed / error
        let lastError: String
    }

    struct SyncedAssignmentData {
        let key: String          // 幂等键，如 "chaoxing:49156357"
        let title: String
        let courseName: String?
        let dueDate: Date?       // 服务器给北京时间 "yyyy-MM-dd HH:mm"
        let isDone: Bool
    }

    struct PlatformSyncResult {
        let accounts: [PlatformAccountStatus]
        let assignments: [SyncedAssignmentData]
    }

    // 北京时间固定 +8，与服务器 strftime 输出对齐（en_US_POSIX 防地区差异解析翻车）
    private static let bjDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// GET /sync/assignments：平台作业全量 + 已绑定账号健康状态（设置页展示的数据源）
    static func fetchPlatformSync(baseURL: String, username: String,
                                  password: String) async throws -> PlatformSyncResult {
        let token = try await ensureToken(baseURL: baseURL, username: username, password: password)
        var request = URLRequest(url: URL(string: trimmedBase(baseURL) + "/sync/assignments")!)
        request.timeoutInterval = 20
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        var (data, response) = try await URLSession.shared.data(for: request)
        // token 失效：重新登录再试一次
        if (response as? HTTPURLResponse)?.statusCode == 401 {
            cachedToken = nil
            tokenFingerprint = nil
            let fresh = try await ensureToken(baseURL: baseURL, username: username, password: password)
            request.setValue("Bearer \(fresh)", forHTTPHeaderField: "Authorization")
            (data, response) = try await URLSession.shared.data(for: request)
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.badServerResponse)
        }
        let accounts = (root["accounts"] as? [[String: Any]] ?? []).map { item in
            PlatformAccountStatus(
                platform: item["platform"] as? String ?? "",
                username: item["username"] as? String ?? "",
                status: item["status"] as? String ?? "error",
                lastError: item["lastError"] as? String ?? "")
        }
        let assignments = (root["assignments"] as? [[String: Any]] ?? []).compactMap { item -> SyncedAssignmentData? in
            guard let key = item["key"] as? String, let title = item["title"] as? String else { return nil }
            let due = (item["dueDate"] as? String).flatMap { bjDateFormatter.date(from: $0) }
            return SyncedAssignmentData(
                key: key,
                title: title,
                courseName: item["courseName"] as? String,
                dueDate: due,
                isDone: item["isDone"] as? Bool ?? false)
        }
        return PlatformSyncResult(accounts: accounts, assignments: assignments)
    }

    /// DELETE /sync/platform-account/{platform}：解绑（服务器同步删掉该平台全部作业）
    static func unbindPlatformAccount(baseURL: String, username: String,
                                      password: String, platform: String) async -> Bool {
        guard let token = try? await ensureToken(baseURL: baseURL, username: username, password: password),
              let url = URL(string: trimmedBase(baseURL) + "/sync/platform-account/\(platform)") else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    /// POST /sync/assignments/refresh：手动触发服务器立即轮询一次（设置页刷新按钮；智慧树走这条）
    static func refreshPlatformAssignments(baseURL: String, username: String,
                                           password: String) async -> Bool {
        guard let token = try? await ensureToken(baseURL: baseURL, username: username, password: password) else { return false }
        guard let (_, response) = try? await post(baseURL: baseURL, path: "/sync/assignments/refresh",
                                                  token: token, body: nil) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    /// POST /sync/assignments/push：端侧直连拉到的作业上报服务器入库
    /// （学习通/智慧树协议都在手机网络跑：学习通被风控拦服务器出口，智慧树被 WAF 拦；
    /// 凭据/会话只存手机 Keychain，服务器不落）
    static func pushAssignments(baseURL: String, username: String, password: String,
                                platform: String, platformUser: String,
                                items: [SyncedAssignmentData],
                                complete: Bool, error: String) async -> Bool {
        let body: [String: Any] = [
            "platform": platform,
            "username": platformUser,
            "complete": complete,
            "error": error,
            "items": items.map { i in
                ["key": i.key, "title": i.title,
                 "courseName": i.courseName ?? NSNull(),
                 "dueDate": i.dueDate.map { bjDateFormatter.string(from: $0) } ?? NSNull(),
                 "isDone": i.isDone] as [String: Any]
            },
        ]
        guard let token = try? await ensureToken(baseURL: baseURL, username: username, password: password),
              let (_, response) = try? await post(baseURL: baseURL, path: "/sync/assignments/push",
                                                  token: token, body: body) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    // 回前台拉取节流：回前台场景平台作业频次低，3 分钟内重复拉没有意义
    private static var lastAssignmentsFetchAt: Date?

    /// 回前台/绑定后的合并入口：
    /// ① 端侧直连拉取（学习通账密 + 智慧树扫码会话都存手机 Keychain，未绑定则跳过；
    ///    协议在手机网络跑——学习通被风控拦服务器出口、智慧树被阿里云 WAF 拦）
    /// ② 服务器作业全量拉取（学习通/智慧树行是端侧 push 的落库结果）
    /// ③ 端侧结果上报服务器入库（拉取失败也上报 error，让设置页账号状态如实显示）
    static func syncAssignmentsIfNeeded(force: Bool = false) async {
        let server = AgentConfigStore.loadServerConfig()
        guard server.isConfigured else { return }
        if !force, let last = lastAssignmentsFetchAt, Date().timeIntervalSince(last) < 180 { return }
        lastAssignmentsFetchAt = Date()

        // ① 端侧直连（哪个平台绑定过拉哪个）
        var cx: ChaoxingClient.SyncOutcome?
        if let creds = ChaoxingClient.Credentials.load() {
            cx = await ChaoxingClient.sync(username: creds.username, password: creds.password)
        }
        var zh: AgentZhsClient.SyncOutcome?
        if AgentZhsClient.Credentials.loadCookieJSON() != nil {
            zh = await AgentZhsClient.sync()
        }

        // ② 服务器全量 + 端侧新结果合成一份（mergeAssignments 的清理逻辑以这份为准）
        var items: [SyncedAssignmentData] = []
        var serverReachable = false
        if let result = try? await fetchPlatformSync(baseURL: server.baseURL,
                                                     username: server.username,
                                                     password: server.password) {
            serverReachable = true
            items = result.assignments
            // 端侧拉取成功的平台用新结果，跳过服务器里的旧行
            if cx?.error.isEmpty == true { items = items.filter { !$0.key.hasPrefix("chaoxing:") } }
            if zh?.error.isEmpty == true { items = items.filter { !$0.key.hasPrefix("zhihuishu:") } }
        }
        if let cx, cx.error.isEmpty { items += cx.items }
        if let zh, zh.error.isEmpty { items += zh.items }

        await MainActor.run {
            if serverReachable {
                mergeAssignments(items)                              // 服务器全量权威，全范围清理
            } else if let cx, cx.error.isEmpty, let zh, zh.error.isEmpty {
                mergeAssignments(items, onlyPrune: ["chaoxing", "zhihuishu"])  // 服务器不可达：只对账端侧拉到的平台
            } else if let cx, cx.error.isEmpty {
                mergeAssignments(cx.items, onlyPrune: ["chaoxing"])
            } else if let zh, zh.error.isEmpty {
                mergeAssignments(zh.items, onlyPrune: ["zhihuishu"])
            }
        }

        // ③ 端侧结果上报（失败不影响本地合并，下次回前台重试；失败也上报 error 保账号状态如实）
        if let cx, let creds = ChaoxingClient.Credentials.load() {
            _ = await pushAssignments(baseURL: server.baseURL, username: server.username,
                                      password: server.password, platform: "chaoxing",
                                      platformUser: creds.username,
                                      items: cx.error.isEmpty ? cx.items : [],
                                      complete: cx.complete, error: cx.error)
        }
        if let zh {
            _ = await pushAssignments(baseURL: server.baseURL, username: server.username,
                                      password: server.password, platform: "zhihuishu",
                                      platformUser: AgentZhsClient.Credentials.nickname,
                                      items: zh.error.isEmpty ? zh.items : [],
                                      complete: zh.complete, error: zh.error)
        }
    }

    /// 平台作业列表 → 本地作业列表合并（幂等 upsert，可重复调用）
    /// 规则：① 本地已有同 sourceKey → 更新标题/课程/截止，平台"已提交"仅单向置完成
    ///       ② 本地没有且平台未完成 → 新增（已完成的历史作业不进列表，避免首绑刷屏）
    ///       ③ 本地同步来的、列表已不返回 → 删除（老师删了作业/平台已清空）
    /// onlyPrune：限定 ③ 的清理平台范围（如服务器不可达时只对账学习通，不误删智慧树行）；
    ///            nil = 全范围清理（服务器全量权威时）
    @MainActor
    static func mergeAssignments(_ items: [SyncedAssignmentData], onlyPrune: Set<String>? = nil) {
        let dm = DataManager.shared
        var homeworks = dm.homeworks
        var changed = false
        let serverKeys = Set(items.map { $0.key })

        for item in items {
            if let idx = homeworks.firstIndex(where: { $0.sourceKey == item.key }) {
                let local = homeworks[idx]
                var updated = local
                if updated.title != item.title { updated.title = item.title; changed = true }
                if updated.courseName != item.courseName { updated.courseName = item.courseName; changed = true }
                if updated.dueDate != item.dueDate { updated.dueDate = item.dueDate; changed = true }
                // 平台显示"已提交"→ 本地标完成；用户手动勾选过的保持完成，不回退
                if item.isDone && !local.isDone {
                    updated.isDone = true
                    updated.completedAt = Date()
                    changed = true
                }
                homeworks[idx] = updated
            } else {
                guard !item.isDone else { continue }  // 历史已完成作业不刷屏
                // 只导入自今天开始的作业（今天截止的算，之前的不导入）
                if let due = item.dueDate, due < Calendar.current.startOfDay(for: Date()) { continue }
                homeworks.append(HomeworkItem(
                    title: item.title,
                    courseName: item.courseName,
                    dueDate: item.dueDate,
                    source: item.key.split(separator: ":").first.map(String.init),
                    sourceKey: item.key))
                changed = true
            }
        }

        let todayStart = Calendar.current.startOfDay(for: Date())
        let before = homeworks.count
        homeworks.removeAll { hw in
            guard let key = hw.sourceKey else { return false }   // 手动添加的作业永不自动删
            // 平台同步来的过期作业不算（截止在今天 0 点之前的全部清走，平台无关）
            if let due = hw.dueDate, due < todayStart { return true }
            if let only = onlyPrune {
                let platform = key.split(separator: ":").first.map(String.init) ?? ""
                return only.contains(platform) && !serverKeys.contains(key)
            }
            return !serverKeys.contains(key)
        }
        if homeworks.count != before { changed = true }

        if changed { dm.replaceAllHomeworks(homeworks) }
    }

    // MARK: 定时任务（Muse 式异步任务）—— 任务中心数据源 + 已读回执 + 取消
    // 免签名无 APNs：结果触达走"端侧拉取 → 本地通知"，见 NotificationManager.refreshAgentTasks
    static func fetchAgentTasks(baseURL: String, username: String,
                                password: String) async throws -> [AgentTaskData] {
        let token = try await ensureToken(baseURL: baseURL, username: username, password: password)
        var request = URLRequest(url: URL(string: trimmedBase(baseURL) + "/agent/tasks")!)
        request.timeoutInterval = 20
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        var (data, response) = try await URLSession.shared.data(for: request)
        // token 失效：重新登录再试一次
        if (response as? HTTPURLResponse)?.statusCode == 401 {
            cachedToken = nil
            tokenFingerprint = nil
            let fresh = try await ensureToken(baseURL: baseURL, username: username, password: password)
            request.setValue("Bearer \(fresh)", forHTTPHeaderField: "Authorization")
            (data, response) = try await URLSession.shared.data(for: request)
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = root["tasks"] as? [[String: Any]] else {
            throw URLError(.badServerResponse)
        }
        return list.compactMap(AgentTaskData.parse)
    }

    /// 把拉取过的任务结果标为已读（角标清零的回执；失败返回 false，下次打开重标）
    static func markAgentTasksRead(baseURL: String, username: String,
                                   password: String, resultIds: [Int]) async -> Bool {
        guard !resultIds.isEmpty else { return true }
        guard let token = try? await ensureToken(baseURL: baseURL, username: username, password: password) else { return false }
        guard let (_, response) = try? await post(baseURL: baseURL, path: "/agent/tasks/read", token: token,
                                                  body: ["result_ids": resultIds]) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    /// 取消任务（软删 → 移入"已结束"；历史结果保留在服务器）
    static func deleteAgentTask(baseURL: String, username: String,
                                password: String, id: Int) async -> Bool {
        guard let token = try? await ensureToken(baseURL: baseURL, username: username, password: password),
              let url = URL(string: trimmedBase(baseURL) + "/agent/tasks/\(id)") else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    // MARK: Bark 推送（服务器主动推送通道：任务结果 / 作业截止提醒 / 平台登录失效告警）
    // 免签名无 APNs：服务器经 Bark（免费 App，自带推送证书）把消息推到锁屏，
    // App 开不开都收得到；Key 在用户手机 Bark App 首页复制，存服务器 users.bark_key。

    /// GET /sync/push-key：读取已保存的 Bark Key（设置页回显；nil=请求失败）
    static func fetchPushKey(baseURL: String, username: String, password: String) async -> String? {
        do {
            let token = try await ensureToken(baseURL: baseURL, username: username, password: password)
            var request = URLRequest(url: URL(string: trimmedBase(baseURL) + "/sync/push-key")!)
            request.timeoutInterval = 20
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            var (data, response) = try await URLSession.shared.data(for: request)
            if (response as? HTTPURLResponse)?.statusCode == 401 {
                cachedToken = nil
                tokenFingerprint = nil
                let fresh = try await ensureToken(baseURL: baseURL, username: username, password: password)
                request.setValue("Bearer \(fresh)", forHTTPHeaderField: "Authorization")
                (data, response) = try await URLSession.shared.data(for: request)
            }
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            return root["bark_key"] as? String ?? ""
        } catch {
            return nil
        }
    }

    /// POST /sync/push-key：保存 Bark Key（空串=关闭推送），服务器随即发一条测试推送
    /// 返回 (是否保存成功, 测试推送是否送达, 失败原因)——reason 带真实原因，
    /// 不再把「密码不对/超时/500」全兜成"服务器暂时连不上"误导排查方向
    static func savePushKey(baseURL: String, username: String, password: String,
                            barkKey: String) async -> (saved: Bool, testOk: Bool, reason: String?) {
        func reasonFor(_ error: Error) -> String {
            if let ns = error as? NSError, ns.domain == "CoursePetAgent" {
                return ns.localizedDescription   // 服务器原话：多为"用户名已被占用但密码不对"
            }
            if let url = error as? URLError {
                switch url.code {
                case .timedOut: return "连接服务器超时，检查网络或服务器地址"
                case .cannotFindHost, .cannotConnectToHost:
                    return "找不到服务器，检查服务器地址"
                default: return "连不上服务器，检查网络"
                }
            }
            return "保存失败：\(error.localizedDescription)"
        }
        do {
            let token = try await ensureToken(baseURL: baseURL, username: username, password: password)
            let body = ["bark_key": barkKey]
            var (data, response) = try await post(baseURL: baseURL, path: "/sync/push-key",
                                                  token: token, body: body)
            if (response as? HTTPURLResponse)?.statusCode == 401 {
                cachedToken = nil
                tokenFingerprint = nil
                let fresh = try await ensureToken(baseURL: baseURL, username: username, password: password)
                (data, response) = try await post(baseURL: baseURL, path: "/sync/push-key",
                                                  token: fresh, body: body)
            }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return (false, false, "服务器返回 HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
            }
            let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            return (true, (root?["test"] as? Bool) == true, nil)
        } catch {
            return (false, false, reasonFor(error))
        }
    }

    // MARK: 登录拿 token（登录 401 时自动注册，首次使用零操作）
    // 非 private：AgentLibraryClient（课件上传/列表）复用同一份 token 缓存，避免二次登录
    static func ensureToken(baseURL: String, username: String,
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

    // 请求构造（普通 POST 与流式 bytes 共用；非 private 供 AgentLibraryClient 复用）
    static func makeRequest(baseURL: String, path: String, token: String?,
                            body: [String: Any]?) -> URLRequest {
        var request = URLRequest(url: URL(string: trimmedBase(baseURL) + path)!)
        request.httpMethod = "POST"
        request.timeoutInterval = 120  // ReAct 多轮 + 推理模型，给足时间
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body { request.httpBody = try? JSONSerialization.data(withJSONObject: body) }
        return request
    }

    // 非 private：AgentLibraryClient 构造带 query 的 URL 时复用
    static func trimmedBase(_ url: String) -> String {
        var base = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.hasSuffix("/") { base.removeLast() }
        return base
    }
}

// MARK: - 定时任务数据结构（与 main.py 的 AgentTaskOut / TaskResultOut 对齐）
// runAt 是北京时间字符串（"yyyy-MM-dd HH:mm"）；createdAt 是 UTC ISO（展示时 +8h）
struct AgentTaskResultData {
    let id: Int
    let content: String
    let isRead: Bool
    let createdAt: String
}

struct AgentTaskData {
    let id: Int
    let title: String
    let scheduleKind: String    // daily / once
    let runTime: String         // daily "HH:MM"（北京时间）；once 为空
    let runAt: String           // once "yyyy-MM-dd HH:mm"（北京时间）；无则空串
    let status: String          // active / done / cancelled
    let lastError: String
    let unreadCount: Int
    let results: [AgentTaskResultData]

    static func parse(_ obj: [String: Any]) -> AgentTaskData? {
        guard let id = obj["id"] as? Int, let title = obj["title"] as? String else { return nil }
        let results = (obj["results"] as? [[String: Any]] ?? []).compactMap { item -> AgentTaskResultData? in
            guard let rid = item["id"] as? Int, let content = item["content"] as? String else { return nil }
            return AgentTaskResultData(id: rid, content: content,
                                       isRead: item["isRead"] as? Bool ?? false,
                                       createdAt: item["createdAt"] as? String ?? "")
        }
        return AgentTaskData(
            id: id,
            title: title,
            scheduleKind: obj["scheduleKind"] as? String ?? "daily",
            runTime: obj["runTime"] as? String ?? "",
            runAt: obj["runAt"] as? String ?? "",
            status: obj["status"] as? String ?? "active",
            lastError: obj["lastError"] as? String ?? "",
            unreadCount: obj["unreadCount"] as? Int ?? 0,
            results: results
        )
    }
}

