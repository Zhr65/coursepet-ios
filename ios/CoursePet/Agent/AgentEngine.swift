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

    init(dataManager: DataManager) {
        self.dataManager = dataManager
    }

    // MARK: 用户发送一条消息（聊天页唯一入口）
    func send(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isThinking else { return }

        history.append(.user(trimmed))
        displayMessages.append(ChatDisplayMessage(kind: .user, text: trimmed))

        isThinking = true
        defer { isThinking = false }

        var round = 0
        while round < maxRounds {
            round += 1
            // 1. 调用 LLM
            let response: AgentMessage
            do {
                response = try await callLLM()
            } catch let error as AgentEngineError {
                displayMessages.append(ChatDisplayMessage(kind: .error, text: error.friendlyText))
                history.append(.assistant(error.friendlyText))
                return
            } catch {
                let text = "网络出了点问题，请检查网络后重试。"
                displayMessages.append(ChatDisplayMessage(kind: .error, text: text))
                history.append(.assistant(text))
                return
            }

            // 2. 模型决定调用工具 → 端侧执行 → 回填 → 继续循环（ReAct 的 "Act" + "再 Reason"）
            if !response.toolCalls.isEmpty {
                history.append(response)
                for call in response.toolCalls {
                    // 界面上展示一条"过程标签"，让用户看到宠物在做什么
                    displayMessages.append(ChatDisplayMessage(kind: .toolTrace, text: Self.traceText(for: call.functionName)))
                    // 找到工具并执行；找不到工具也回填错误文本（模型会自行纠正）
                    guard let tool = Self.tools.first(where: { $0.name == call.functionName }) else {
                        history.append(.toolResult(id: call.id, name: call.functionName, content: "未知工具：\(call.functionName)"))
                        continue
                    }
                    let result = await AgentToolRegistry.run(tool, argumentsJSON: call.argumentsJSON)
                    history.append(.toolResult(id: call.id, name: call.functionName, content: result))
                }
                continue
            }

            // 3. 无工具调用 → 最终回答，结束循环
            let answer = response.content.isEmpty ? "（我好像走神了，再说一遍？）" : response.content
            history.append(.assistant(answer))
            displayMessages.append(ChatDisplayMessage(kind: .assistant, text: answer))
            trimHistory()
            return
        }

        // 超过轮数上限：如实告诉用户（宁可示弱也不编答案）
        let text = "这个问题我查了好几轮还没搞定，要不换个问法？"
        displayMessages.append(ChatDisplayMessage(kind: .assistant, text: text))
        history.append(.assistant(text))
    }

    // MARK: 调用 LLM（OpenAI 兼容 chat/completions + tools）
    private func callLLM() async throws -> AgentMessage {
        let config = AgentConfigStore.load()
        guard config.isConfigured else {
            throw AgentEngineError.notConfigured
        }

        // 组装 messages：system 恒驻第一条 + 对话历史
        var payloadMessages: [[String: Any]] = [
            ["role": "system", "content": AgentPromptBuilder.buildSystemPrompt(dataManager: dataManager)]
        ]
        for msg in history {
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

        // 工具 schema 列表
        let toolsPayload = Self.tools.map { tool -> [String: Any] in
            [
                "type": "function",
                "function": [
                    "name": tool.name,
                    "description": tool.description,
                    "parameters": tool.parametersSchema
                ]
            ]
        }

        let body: [String: Any] = [
            "model": config.model,
            "messages": payloadMessages,
            "tools": toolsPayload,
            "temperature": 0.6,
            "max_tokens": 800
        ]

        var request = URLRequest(url: URL(string: config.baseURL + "/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, httpResponse) = try await URLSession.shared.data(for: request)
        guard let http = httpResponse as? HTTPURLResponse else {
            throw AgentEngineError.network
        }
        guard http.statusCode == 200 else {
            if http.statusCode == 401 { throw AgentEngineError.badAPIKey }
            if http.statusCode == 429 { throw AgentEngineError.rateLimited }
            throw AgentEngineError.network
        }

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
