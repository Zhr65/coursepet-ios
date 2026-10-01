// MARK: - 宠物形象生成（阿里百炼 DashScope 文生图，qwen-image-3.0 异步任务）
// 链路：提交异步生图任务拿 task_id → 每 2.5s 轮询任务状态（封顶约 150s）→ 下载图片 →
//       落盘沙盒 Documents/generated/{uuid}.png → 暂存 pendingImage 供引擎插入聊天流。
// Key 独立于主模型 Key（阿里百炼 dashscope 专用），存取复用 AgentConfigStore 的
// Keychain 条目体系（service 不变，account 分片隔离），UserDefaults 镜像兜底。
// 注意：生成的图与帧动画 pet_{action}_{frame}.png 命名体系隔离，互不干扰。
import Foundation
import UIKit

@MainActor
enum AgentImageGen {

    // MARK: 错误（转成用户能看懂的中文提示）
    enum GenError: LocalizedError {
        case notConfigured
        case network
        case submitFailed(String)
        case taskFailed(String)
        case timeout
        case downloadFailed

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "我还没拿到画笔的钥匙！请到 设置 → AI 管家 → 端侧模式，填入「图像生成 Key（阿里百炼）」。"
            case .network:
                return "网络出了点问题，这张图没画成，稍后再试一次。"
            case .submitFailed(let msg):
                return "画图服务拒绝了请求：\(msg)。如果是 Key 的问题，请到设置页检查「图像生成 Key」。"
            case .taskFailed(let msg):
                return "这张图没画成（\(msg)）。可能是描述触发了内容审核，换个说法再试试。"
            case .timeout:
                return "画得太久超过了等待上限，先放弃了，稍后再试一次。"
            case .downloadFailed:
                return "图已经画好了，但下载失败了，稍后再试一次。"
            }
        }
    }

    // MARK: Key 存取（Keychain 主体，UserDefaults 镜像兜底；删 App 重装不丢）
    private static let keychainAccount = "dashscopeKey"
    private static let fallbackKey = "agent.dashscopeKey"

    static func loadKey() -> String {
        if let key = AgentConfigStore.readExtraKey(account: keychainAccount), !key.isEmpty {
            return key
        }
        return UserDefaults.standard.string(forKey: fallbackKey) ?? ""
    }

    static func saveKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if AgentConfigStore.writeExtraKey(trimmed, account: keychainAccount) {
            UserDefaults.standard.removeObject(forKey: fallbackKey)
        } else {
            // Keychain 不可用（免签名构建常见）：降级 UserDefaults 保功能可用
            UserDefaults.standard.set(trimmed, forKey: fallbackKey)
        }
    }

    static var isConfigured: Bool { !loadKey().isEmpty }

    // MARK: 引擎桥接：工具执行成功后暂存图片，引擎取走插入聊天流（模型只拿文本摘要）
    private(set) static var pendingImage: Data?

    static func consumePendingImage() -> Data? {
        let data = pendingImage
        pendingImage = nil
        return data
    }

    // MARK: 生图主链路：prompt → 提交 → 轮询 → 下载 → 落盘 → 暂存
    /// 返回给模型的文本摘要（图片本身经 pendingImage 交给展示层）
    static func generate(_ prompt: String) async throws -> String {
        let key = loadKey()
        guard !key.isEmpty else { throw GenError.notConfigured }

        // 1. 提交异步任务
        let taskID = try await submitTask(prompt: prompt, key: key)

        // 2. 轮询任务状态（2.5s 一次，封顶 60 次 ≈ 150s）
        let imageURL = try await pollTask(taskID: taskID, key: key)

        // 3. 下载图片
        let (data, resp) = try await URLSession.shared.data(from: imageURL)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200, !data.isEmpty else {
            throw GenError.downloadFailed
        }

        // 4. 落盘：Documents/generated/{uuid}.png（与帧动画 pet_* 命名体系隔离）
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("generated", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileName = "\(UUID().uuidString).png"
        try data.write(to: dir.appendingPathComponent(fileName))

        // 5. 暂存给引擎插入聊天流
        pendingImage = data
        return "图片已生成并插入聊天，本地文件 generated/\(fileName)。在最终回答里告诉主人画好了什么即可，不要重复调用本工具。"
    }

    // MARK: DashScope 异步文生图协议（qwen-image-3.0，固定 1024*1024 不暴露参数）
    private static let model = "qwen-image-3.0"

    private static func submitTask(prompt: String, key: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://dashscope.aliyuncs.com/api/v1/services/aigc/text2image/image-synthesis")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("enable", forHTTPHeaderField: "X-DashScope-Async")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = [
            "model": model,
            "input": ["prompt": prompt],
            "parameters": ["size": "1024*1024", "n": 1]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: request)
        guard let http = resp as? HTTPURLResponse,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GenError.network
        }
        guard http.statusCode == 200,
              let output = obj["output"] as? [String: Any],
              let taskID = output["task_id"] as? String, !taskID.isEmpty else {
            // 401 = Key 不对；429 = 限流；其余带服务端 message
            throw GenError.submitFailed((obj["message"] as? String) ?? "HTTP \(http.statusCode)")
        }
        return taskID
    }

    private static func pollTask(taskID: String, key: String) async throws -> URL {
        var request = URLRequest(url: URL(string: "https://dashscope.aliyuncs.com/api/v1/tasks/\(taskID)")!)
        request.timeoutInterval = 15
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        for _ in 0..<60 {
            try await Task.sleep(nanoseconds: 2_500_000_000)
            let (data, resp) = try await URLSession.shared.data(for: request)
            // 单次轮询失败不放弃（网络抖动），等下一轮
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let output = obj["output"] as? [String: Any],
                  let status = output["task_status"] as? String else { continue }
            switch status {
            case "SUCCEEDED":
                guard let results = output["results"] as? [[String: Any]],
                      let urlString = results.first?["url"] as? String,
                      let url = URL(string: urlString) else {
                    throw GenError.taskFailed("任务成功但没拿到图片地址")
                }
                return url
            case "FAILED", "UNKNOWN", "CANCELED":
                let msg = (output["message"] as? String) ?? (output["code"] as? String) ?? "未知原因"
                throw GenError.taskFailed(msg)
            default:
                continue // PENDING / RUNNING，继续等
            }
        }
        throw GenError.timeout
    }
}
