// MARK: - Agent 引擎（ReAct 循环核心）
// 一次完整交互的流程：
//   用户输入 → [循环开始] → 调 LLM → 模型返回 tool_calls？
//     ├─ 是：逐个在端侧执行工具 → 结果以 role:tool 回填 → 回到循环开头（最多 maxRounds 轮）
//     └─ 否：模型给出最终自然语言回答 → 展示 → 结束
// 关键设计：
//   1. 终止条件：maxRounds 上限防死循环；工具异常不抛出而是作为结果回填，让模型"自愈"。
//   2. 历史管理：system 恒驻 + 最近 keepRounds 轮对话（控制上下文长度 = 控制 token 成本）。
//   3. 无第三方依赖：请求/响应用 JSONSerialization 构造解析（LLM 协议字段动态，强类型 Codable 反而别扭）。
import Foundation
import UIKit

@MainActor
final class AgentEngine: ObservableObject {
    /// 聊天界面的展示消息（用户/宠物/过程标签）
    @Published private(set) var displayMessages: [ChatDisplayMessage] = []
    /// 是否正在思考/调用工具中（驱动输入框禁用与动画）
    @Published private(set) var isThinking = false

    /// 引擎内对话历史（不含 system；发送时与 system prompt 组装）
    private var history: [AgentMessage] = []
    private let dataManager: DataManager
    private let maxRounds = 5        // 单次提问最多"模型→工具"往返次数，防死循环
    private let keepRounds = 6       // 长期历史保留最近 6 轮（12 条消息）
    /// 对话记录侧栏的当前会话 id（reset 时换新，旧会话留在记录里可回看）
    private var archiveSessionID = UUID()

    init(dataManager: DataManager) {
        self.dataManager = dataManager
    }

    /// 清空历史与界面，开始新对话（"新对话"按钮；system prompt 每次请求实时生成，无需缓存）
    func reset() {
        history = []
        displayMessages = []
        archiveSessionID = UUID()

        // 服务器模式：同步清空服务器端对话历史（不阻塞 UI，失败静默）
        let server = AgentConfigStore.loadServerConfig()
        if server.isConfigured {
            Task {
                await AgentRemoteClient.clearHistory(baseURL: server.baseURL,
                                                     username: server.username,
                                                     password: server.password)
            }
        }
    }

    /// 无 UI 场景跑一轮（Siri / AppIntents 调用）：返回最终回答文本。
    /// 复用 send 的完整双模式逻辑（端侧 ReAct / 服务器转发），
    /// 从本次新增消息里提取最后一条助手回复；错误提示文案本身就是指引，也视为回答。
    func askOnce(_ text: String) async -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "想问什么呀？说具体一点" }
        let before = displayMessages.count
        await send(trimmed)
        let added = displayMessages.suffix(from: min(before, displayMessages.count))
        if let answer = added.last(where: { msg in
            if case .assistant = msg.kind { return true }
            return false
        })?.text {
            return answer
        }
        if let error = added.last(where: { msg in
            if case .error = msg.kind { return true }
            return false
        })?.text {
            return error
        }
        return "我好像走神了，再问一次试试"
    }

    // MARK: 用户发送一条消息（聊天页唯一入口；image 非空 = 拍照多模态）
    func send(_ text: String, image: UIImage? = nil) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || image != nil, !isThinking else { return }
        // 只发图没配文字时补一句引导语（服务端 message 字段要求非空）
        let outgoing = trimmed.isEmpty ? "帮我看看这个" : trimmed

        // V2 服务器模式：设置页填了服务器配置 → 转发给后端执行（ReAct 在服务端跑）
        let server = AgentConfigStore.loadServerConfig()
        if server.isConfigured {
            await sendViaServer(outgoing, image: image, server: server)
            return
        }
        // 端侧模式（V1）：ReAct 在本机执行，Key 存 Keychain
        await sendOnDevice(outgoing, image: image)
    }

    /// 端侧模式：原 V1 逻辑（历史在本机、工具读写本机 DataManager）
    private func sendOnDevice(_ trimmed: String, image: UIImage?) async {
        // 压缩一次：base64 发 LLM，同份 Data 顺手做气泡缩略图
        let imageData = image.flatMap { AgentImageCompressor.compress($0) }
        // 历史里旧图的 base64 全部丢弃（各自当轮已用过）：只保留本轮图片，防止 token 随对话轮数膨胀
        for i in history.indices where history[i].role == .user {
            history[i].imageBase64 = nil
        }
        history.append(.user(trimmed, image: imageData?.base64EncodedString()))
        displayMessages.append(ChatDisplayMessage(kind: .user, text: trimmed, imageData: imageData))
        // 对话记录侧栏：用户消息即时落盘（图片不存——体积大且当轮已用过）
        AgentChatArchive.record(sessionID: archiveSessionID, role: "user", text: trimmed)

        isThinking = true
        defer { isThinking = false }

        // 幂等缓存：整个 send 过程跨 ReAct 轮次共享，key = 工具名 + 参数原文
        var toolCache: [String: String] = [:]
        var round = 0
        while round < maxRounds {
            round += 1
            // 1. 调用 LLM
            let response: AgentMessage
            do {
                response = try await callLLM(query: trimmed)
            } catch let error as AgentEngineError {
                // 带图请求失败时优先怀疑模型不支持识图（比"网络问题"更接近真相、更可操作）
                var text = error.friendlyText
                if imageData != nil && (error == .network || error == .badResponse) {
                    text = "这张图没能识别（当前模型可能不支持看图）：换个支持视觉的模型试试，或直接用文字告诉我。"
                }
                displayMessages.append(ChatDisplayMessage(kind: .error, text: text))
                history.append(.assistant(text))
                return
            } catch {
                let text = imageData != nil
                    ? "这张图没能识别（当前模型可能不支持看图）：换个支持视觉的模型试试，或直接用文字告诉我。"
                    : "网络出了点问题，请检查网络后重试。"
                displayMessages.append(ChatDisplayMessage(kind: .error, text: text))
                history.append(.assistant(text))
                return
            }

            // 2. 模型决定调用工具 → 端侧执行 → 回填 → 继续循环（ReAct 的 "Act" + "再 Reason"）
            if !response.toolCalls.isEmpty {
                history.append(response)
                for call in response.toolCalls {
                    // 模式 11：show_card 在端侧直接把参数渲染成卡片消息（不显示过程标签——卡片本身已是可视化结果）
                    if call.functionName == "show_card" {
                        if let card = AgentCard.parse(call.argumentsJSON) {
                            displayMessages.append(ChatDisplayMessage(kind: .card(card), text: call.argumentsJSON))
                            // 活动时间线：出卡也是它干过的一件事
                            ActivityLogger.logCard(title: card.title, itemCount: card.items.count)
                            history.append(.toolResult(
                                id: call.id, name: call.functionName,
                                content: "卡片已插入聊天（\(card.title)，\(card.items.count) 条）。文字回答里不要再重复卡片里的数据。"))
                        } else {
                            history.append(.toolResult(
                                id: call.id, name: call.functionName,
                                content: "卡片参数不合法：cardType 必须是 homework/schedule/bill/jump，items 至少 1 条（每条含 primary）。"))
                        }
                        continue
                    }
                    // 幂等拦截：同一轮对话里完全相同的调用（写类工具被推理模型重复触发）直接拦截，
                    // 防止"记一笔变两笔"；读类工具命中缓存也省一次执行（拦截时不显示过程标签，避免误导）
                    let cacheKey = call.functionName + "|" + call.argumentsJSON
                    if toolCache[cacheKey] != nil {
                        history.append(.toolResult(
                            id: call.id, name: call.functionName,
                            content: "（重复调用已拦截——这条刚刚已经处理过了，请直接回答用户。）"))
                        continue
                    }
                    // 界面上展示一条"过程标签"，让用户看到宠物在做什么（放在幂等检查后：拦截的调用不上屏）
                    let traceLabel = Self.traceText(for: call.functionName)
                    displayMessages.append(ChatDisplayMessage(kind: .toolTrace(traceLabel), text: traceLabel))
                    // 找到工具并执行；找不到工具也回填错误文本（模型会自行纠正）
                    guard let tool = tools.first(where: { $0.name == call.functionName }) else {
                        history.append(.toolResult(id: call.id, name: call.functionName, content: "未知工具：\(call.functionName)"))
                        continue
                    }
                    let result = await AgentToolRegistry.run(tool, argumentsJSON: call.argumentsJSON)
                    toolCache[cacheKey] = result
                    history.append(.toolResult(id: call.id, name: call.functionName, content: result))
                    // 生图工具：把暂存的图片直接插进聊天流（模型只拿到文本摘要，图片走展示层；
                    // 重复调用被幂等拦截时 consume 返回 nil，不会重复出图）
                    if call.functionName == "generate_image",
                       let imgData = AgentImageGen.consumePendingImage() {
                        displayMessages.append(ChatDisplayMessage(kind: .image(imgData), text: result))
                    }
                    // 活动时间线：工具执行成功就留痕（读类也记，Muse 式完整活动流）
                    ActivityLogger.logToolCall(name: call.functionName, argumentsJSON: call.argumentsJSON, result: result)
                }
                continue
            }

            // 3. 无工具调用 → 最终回答，结束循环
            let answer = response.content.isEmpty ? "（我好像走神了，再说一遍？）" : response.content
            history.append(.assistant(answer))
            displayMessages.append(ChatDisplayMessage(kind: .assistant, text: answer))
            AgentChatArchive.record(sessionID: archiveSessionID, role: "assistant", text: answer)
            // 本轮累积的读类查询合并成一条活动（"回答了你的问题：查了 N 项"）
            ActivityLogger.flushReadSummary()
            // 有活跃课程灵动岛时，让宠物在锁屏卡片上"开口"说出这条回复
            LiveActivityManager.updateAgentReply(answer)
            // 端侧长期记忆：异步提取值得记住的事实（fire-and-forget，失败静默不阻塞）
            let asked = trimmed
            Task { await AgentMemoryStore.maybeExtractFrom(lastUser: asked, lastAnswer: answer) }
            trimHistory()
            return
        }

        // 超过轮数上限：如实告诉用户（宁可示弱也不编答案）
        let text = "这个问题我查了好几轮还没搞定，要不换个问法？"
        displayMessages.append(ChatDisplayMessage(kind: .assistant, text: text))
        history.append(.assistant(text))
        AgentChatArchive.record(sessionID: archiveSessionID, role: "assistant", text: text)
    }

    /// 从对话记录恢复会话（侧栏点击）：重建展示消息与端侧历史。
    /// 服务器模式只重建 UI——续聊上下文由服务端 conversation_messages 单线管理。
    func loadSession(_ session: ArchivedChatSession) {
        displayMessages = session.messages.map { m in
            m.role == "user"
                ? ChatDisplayMessage(kind: .user, text: m.text)
                : ChatDisplayMessage(kind: .assistant, text: m.text)
        }
        history = session.messages.suffix(keepRounds * 2).map { m in
            m.role == "user" ? AgentMessage.user(m.text) : AgentMessage.assistant(m.text)
        }
        archiveSessionID = session.id
    }

    /// 服务器模式（V2）：本地只做 UI 展示，ReAct 循环与数据读写都在后端完成。
    /// 流式渲染：过程标签即时上屏，最终回答后到（服务器无流式端点时客户端自动回落）。
    private func sendViaServer(_ text: String, image: UIImage? = nil, server: AgentConfigStore.ServerConfig) async {
        isThinking = true
        defer { isThinking = false }
        let imageData = image.flatMap { AgentImageCompressor.compress($0) }
        displayMessages.append(ChatDisplayMessage(kind: .user, text: text, imageData: imageData))
        // 对话记录侧栏：用户消息即时落盘（服务器模式同样记录，侧栏统一视图）
        AgentChatArchive.record(sessionID: archiveSessionID, role: "user", text: text)

        // 数据同源（原则 7）：对话前把本地课表/快递推给服务器（有变化才推，失败静默不影响聊天），
        // 保证服务器 Agent 查的数据与手机端完全一致
        await AgentRemoteClient.syncCoursesIfNeeded(baseURL: server.baseURL,
                                                    username: server.username,
                                                    password: server.password)
        await AgentRemoteClient.syncParcelsIfNeeded(baseURL: server.baseURL,
                                                    username: server.username,
                                                    password: server.password)

        do {
            var receivedAny = false
            var lastAnswer = ""
            // 系统日历只读注入：今天的日程随请求带给服务器（未授权/无日程为空串，零开销，绝不弹窗）
            let calendarContext = EventKitManager.todayEventsText()
            for try await msg in AgentRemoteClient.chatStream(
                baseURL: server.baseURL,
                username: server.username,
                password: server.password,
                message: text,
                image: imageData?.base64EncodedString(),
                calendarContext: calendarContext) {
                receivedAny = true
                displayMessages.append(msg)
                if case .assistant = msg.kind { lastAnswer = msg.text }
            }
            if !receivedAny {
                displayMessages.append(ChatDisplayMessage(kind: .error, text: "服务器返回了空回复，再问一次试试。"))
            } else if !lastAnswer.isEmpty {
                // 有活跃课程灵动岛时，让宠物在锁屏卡片上"开口"说出这条回复
                LiveActivityManager.updateAgentReply(lastAnswer)
                AgentChatArchive.record(sessionID: archiveSessionID, role: "assistant", text: lastAnswer)
            }
        } catch let error as URLError {
            // 把系统错误翻译成可操作的指引（失败也要有用：报错即指路）
            let hint: String
            switch error.code {
            case .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost:
                hint = "服务器地址打不开（域名不存在或隧道已重启换新地址）。去 设置 → AI 管家 → 服务器模式 更新地址；不想用服务器就清空地址保存，回到端侧模式。"
            case .timedOut:
                hint = "服务器半天没回音（可能在启动或网络不稳），稍等几秒再试一次。"
            case .notConnectedToInternet:
                hint = "手机没有网络连接，检查一下 Wi-Fi 或蜂窝数据。"
            case .networkConnectionLost:
                hint = "网络连接中断了，重试一次。"
            default:
                hint = "去 设置 → AI 管家 → 服务器模式 检查三项配置，或清空地址回到端侧模式。"
            }
            displayMessages.append(ChatDisplayMessage(kind: .error, text: "服务器暂时够不着：\(hint)"))
        } catch {
            let errorMsg = "服务器连接失败：\(error.localizedDescription)"
            displayMessages.append(ChatDisplayMessage(kind: .error, text: errorMsg))
        }
    }

    // MARK: 调用 LLM（OpenAI 兼容 chat/completions + tools）
    private func callLLM(query: String) async throws -> AgentMessage {
        let config = AgentConfigStore.load()
        guard config.isConfigured else {
            throw AgentEngineError.notConfigured
        }

        // 组装 messages：system 恒驻第一条 + 对话历史
        var payloadMessages: [[String: Any]] = [
            ["role": "system", "content": AgentPromptBuilder.buildSystemPrompt(dataManager: dataManager, query: query)]
        ]
        for msg in history {
            // 拍照多模态：带图 user 消息转 OpenAI vision content parts（base64 data URL）
            if msg.role == .user, let b64 = msg.imageBase64 {
                var parts: [[String: Any]] = []
                if !msg.content.isEmpty {
                    parts.append(["type": "text", "text": msg.content])
                }
                parts.append(["type": "image_url",
                              "image_url": ["url": "data:image/jpeg;base64,\(b64)"]])
                payloadMessages.append(["role": "user", "content": parts])
                continue
            }
            var m: [String: Any] = ["role": msg.role.rawValue, "content": msg.content]
            if !msg.toolCalls.isEmpty {
                m["tool_calls"] = msg.toolCalls.map { call in
                    [
                        "id": call.id,
                        "type": "function",
                        "function": ["name": call.functionName, "arguments": call.argumentsJSON]
                    ]
                }
                // 纯工具调用轮 content 允许为空串
                m["content"] = msg.content
            }
            if let id = msg.toolCallID {
                m["tool_call_id"] = id
            }
            payloadMessages.append(m)
        }

        // 场景路由：带图消息（拍照识别）自动切「图像理解模型」；未配置则跟随主模型。
        // 同一家服务商共用接口地址与 Key（如主 glm-4.7-flash + 视觉 glm-5.3-flash）
        let hasImages = payloadMessages.contains { msg in
            (msg["content"] as? [[String: Any]])?.contains { ($0["type"] as? String) == "image_url" } ?? false
        }
        let effectiveModel = (hasImages && !config.visionModel.isEmpty) ? config.visionModel : config.model

        // 工具 schema 列表
        let toolsPayload = tools.map { tool -> [String: Any] in
            [
                "type": "function",
                "function": [
                    "name": tool.name,
                    "description": tool.description,
                    "parameters": tool.parametersSchema
                ]
            ]
        }

        var body: [String: Any] = [
            "model": effectiveModel,
            "messages": payloadMessages,
            "tools": toolsPayload,
            "temperature": 0.6,
            "max_tokens": 800
        ]
        // GLM 系（glm-4.7-flash / glm-5.x-flash 等）默认开思考模式：ReAct 循环本身就是
        // 外置思考，模型内部思考纯浪费——响应慢、输出 token 翻倍、免费档 TPM 更易撞墙。
        // 对 glm 前缀模型显式关掉；其他家（DeepSeek/agnes）不认这个参数就不传。
        if effectiveModel.lowercased().hasPrefix("glm") {
            body["thinking"] = ["type": "disabled"]
        }

        var request = URLRequest(url: URL(string: config.baseURL + "/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        // 退避重试：agnes 瞬时 429/5xx/网络抖动不再直接甩错误给用户；
        // 5xx/网络抖动用短退避（1.5s/3s）快速重试；429 是分钟窗口限流，
        // 短退避熬不过窗口（实测连续工具轮 3+ 连击就撞墙），改用长退避
        // 9s/15s/21s（4 次尝试共跨约 45 秒），绝大多数窗口限流都能等到放行。
        // 401（Key 错）与 400 类（如模型不支持识图）不重试。
        var success: (data: Data, http: HTTPURLResponse)? = nil
        var lastError: AgentEngineError = .network
        var lastWasRateLimit = false
        for attempt in 0..<4 {
            if attempt > 0 {
                let delay = lastWasRateLimit ? Double(attempt) * 6.0 + 3.0 : Double(attempt) * 1.5
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                lastWasRateLimit = false
            }
            do {
                let (d, resp) = try await URLSession.shared.data(for: request)
                guard let http = resp as? HTTPURLResponse else { lastError = .network; continue }
                switch http.statusCode {
                case 200:
                    success = (d, http)
                case 401:
                    throw AgentEngineError.badAPIKey
                case 429:
                    lastError = .rateLimited
                    lastWasRateLimit = true
                case 500...:
                    lastError = .network
                default:
                    throw AgentEngineError.network
                }
            } catch let e as AgentEngineError {
                throw e
            } catch {
                lastError = .network
            }
            if success != nil { break }
        }
        guard let (data, http) = success else { throw lastError }

        // 解析响应：choices[0].message（可能带 tool_calls）
        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = root["choices"] as? [[String: Any]],
            let first = choices.first,
            let message = first["message"] as? [String: Any]
        else { throw AgentEngineError.badResponse }

        let content = (message["content"] as? String) ?? ""
        var calls: [AgentToolCall] = []
        if let rawCalls = message["tool_calls"] as? [[String: Any]] {
            for raw in rawCalls {
                guard
                    let id = raw["id"] as? String,
                    let function = raw["function"] as? [String: Any],
                    let name = function["name"] as? String
                else { continue }
                calls.append(AgentToolCall(
                    id: id,
                    functionName: name,
                    argumentsJSON: (function["arguments"] as? String) ?? "{}"
                ))
            }
        }
        return AgentMessage(role: .assistant, content: content, toolCalls: calls)
    }

    /// 工具全集（按当前 DataManager 构建）
    private var tools: [AgentTool] {
        AgentToolRegistry.allTools(dataManager: dataManager)
    }

    /// 历史裁剪：只保留最近 keepRounds 轮（一条 user + 一条 assistant 算一轮）
    private func trimHistory() {
        let keep = keepRounds * 2
        if history.count > keep {
            history = Array(history.suffix(keep))
        }
    }

    /// 工具名 → 用户能看懂的过程标签
    private static func traceText(for toolName: String) -> String {
        switch toolName {
        case "get_today_schedule":   return "🔍 翻了翻今天的课表"
        case "get_next_class":       return "🔍 看了看下节课"
        case "get_pending_homeworks":return "📝 数了数没做完的作业"
        case "add_homework":         return "✍️ 帮你记下这条待办"
        case "add_parcel_from_sms":  return "📦 帮你记下了这个快递"
        case "add_ledger_entry":     return "💰 帮你记下这笔账"
        case "get_month_expense":    return "📊 算了算这个月的账"
        case "get_step_count":       return "👟 看了看今天的步数"
        case "get_weather":          return "🌤 瞄了眼今天的天气"
        case "generate_image":       return "🎨 正在画画，要等一小会儿…"
        default:                     return "🔍 查了一下"
        }
    }
}

// MARK: 引擎层错误（转成用户友好的提示文案）
enum AgentEngineError: Error {
    case notConfigured
    case badAPIKey
    case rateLimited
    case network
    case badResponse

    var friendlyText: String {
        switch self {
        case .notConfigured: return "我还没接到大脑呢！请到 设置 → AI 管家 填入 API Key。"
        case .badAPIKey:     return "API Key 好像不对（服务端返回 401），去设置里检查一下吧。"
        case .rateLimited:   return "调用太频繁啦，休息几秒再试。"
        case .network:       return "网络出了点问题，请检查网络后重试。"
        case .badResponse:   return "大脑返回了奇怪的内容，再问一次试试。"
        }
    }
}

// MARK: 拍照多模态图片压缩（发 LLM 前控制 base64 体积：最长边 1024 的 JPEG）
enum AgentImageCompressor {
    /// 压缩为 JPEG Data（最长边 1024，质量 0.7）；失败返回 nil
    static func compress(_ image: UIImage) -> Data? {
        let maxEdge: CGFloat = 1024
        let size = image.size
        let scale = max(size.width, size.height) > maxEdge ? maxEdge / max(size.width, size.height) : 1
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        let resized = UIGraphicsImageRenderer(size: target).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return resized.jpegData(compressionQuality: 0.7)
    }
}
