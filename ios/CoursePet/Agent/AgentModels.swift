// MARK: - Agent 数据模型
// 定义"宠物管家"对话系统的核心数据结构。
// 三类消息与 OpenAI Function Calling 协议对齐：
//   user      → 用户说的话
//   assistant → 模型的回复；若模型决定调用工具，则附带 toolCalls（不说话只调工具）
//   tool      → 本地工具的执行结果，通过 toolCallId 关联回那次调用
import Foundation

// MARK: 一次工具调用请求（模型发起）
struct AgentToolCall {
    let id: String            // 调用唯一 id，回填结果时必须带上
    let functionName: String  // 要调用的工具名
    let argumentsJSON: String // 参数 JSON 字符串，如 "{\"title\":\"高数作业\"}"
}

// MARK: 引擎内部的消息表示（与 API 协议解耦）
struct AgentMessage {
    enum Role: String {
        case system = "system"
        case user = "user"
        case assistant = "assistant"
        case tool = "tool"
    }
    var role: Role
    var content: String
    /// assistant 消息可能附带的工具调用（模型决定"我要查一下"）
    var toolCalls: [AgentToolCall] = []
    /// tool 消息必须携带的调用 id（告诉模型这个结果对应哪次调用）
    var toolCallID: String? = nil

    static func user(_ text: String) -> AgentMessage {
        AgentMessage(role: .user, content: text)
    }
    static func assistant(_ text: String) -> AgentMessage {
        AgentMessage(role: .assistant, content: text)
    }
    static func toolResult(id: String, name: String, content: String) -> AgentMessage {
        AgentMessage(role: .tool, content: content, toolCallID: id)
    }
}

// MARK: 聊天界面的展示消息（UI 层专用，比引擎消息多一个"工具调用过程"标签）
struct ChatDisplayMessage: Identifiable {
    enum Kind {
        case user                       // 用户气泡
        case assistant                  // 宠物回复气泡
        case toolTrace(String)          // "🔍 查了一下课表…" 过程标签
        case error                      // 出错提示
    }
    let id = UUID()
    let kind: Kind
    let text: String
}

// MARK: Agent 配置（设置页可改，Key 存 Keychain）
struct AgentConfig {
    /// OpenAI 兼容端点，默认 DeepSeek（国内直连、便宜、Function Calling 稳定）
    var baseURL: String
    /// API Key（不落 UserDefaults，只进 Keychain）
    var apiKey: String
    /// 模型名，如 deepseek-chat
    var model: String

    static let `default` = AgentConfig(
        baseURL: "https://api.deepseek.com/v1",
        apiKey: "",
        model: "deepseek-chat"
    )

    var isConfigured: Bool { !apiKey.isEmpty && !baseURL.isEmpty && !model.isEmpty }
}
