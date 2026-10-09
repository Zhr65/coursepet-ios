// MARK: - 轻量单次 LLM 调用（无历史无工具，后台场景用）
// 使用方：事件主动提醒（PetEventNudger）等"不进聊天流"的后台生成。
// 与 AgentEngine.callLLM 同款请求风格（OpenAI 格式 + glm 关思考），
// 但刻意不带重试：后台通知晚一两分钟无所谓，失败直接回落模板文案。
import Foundation

enum AgentQuickLLM {

    /// 单次调用，返回清洗后的纯文本；未配置 Key / 失败 / 空回复一律返回 nil
    static func ask(system: String, user: String, maxTokens: Int = 120) async -> String? {
        let config = AgentConfigStore.load()
        guard config.isConfigured,
              let url = URL(string: config.baseURL + "/chat/completions") else { return nil }

        var body: [String: Any] = [
            "model": config.model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
            "temperature": 0.7,
            "max_tokens": maxTokens,
        ]
        // GLM 系默认开思考模式，后台短文案纯浪费，显式关掉（同 AgentEngine 惯例）
        if config.model.lowercased().hasPrefix("glm") {
            body["thinking"] = ["type": "disabled"]
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else { return nil }

        // 清洗：去首尾空白 + 剥掉可能出现的 markdown 包裹（后台通知不接受格式符号）
        let trimmed = content
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "*#`"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
