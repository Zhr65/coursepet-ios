// MARK: - Bark 推送（端侧直发，双处共用）
// 使用方：①短信事件路由（SMSEventRouter）②事件主动提醒（PetEventNudger）。
// 免签名无 APNs，Bark 是唯一"App 关着也收得到"的通道：POST api.day.app/push。
// Key 从服务器回读一次后缓存本地；短信/事件原文只发 Bark 官方接口，不经过咱们服务器。
import Foundation

enum BarkPush {

    /// 发一条 Bark 推送（静默失败：Bark 只是镜像，本地通知才是保底）
    static func send(title: String, body: String, group: String = "CoursePet") {
        Task {
            guard let key = await deviceKey() else { return }
            var req = URLRequest(url: URL(string: "https://api.day.app/push")!)
            req.httpMethod = "POST"
            req.timeoutInterval = 10
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: [
                "device_key": key,
                "title": title,
                "body": body,
                "group": group,
            ])
            _ = try? await URLSession.shared.data(for: req)
        }
    }

    /// 读 Bark Key：本地缓存优先；未缓存且配置了服务器时回读一次。
    /// fetchPushKey：nil = 请求失败（不缓存，下次再试）；"" = 用户没配 Key（缓存空串不再打服务器）
    private static func deviceKey() async -> String? {
        let ud = UserDefaults.standard
        if let cached = ud.string(forKey: "bark.cachedKey") {
            return cached.isEmpty ? nil : cached
        }
        let server = AgentConfigStore.loadServerConfig()
        guard server.isConfigured else { return nil }
        guard let key = await AgentRemoteClient.fetchPushKey(
            baseURL: server.baseURL, username: server.username, password: server.password) else {
            return nil
        }
        ud.set(key, forKey: "bark.cachedKey")
        return key.isEmpty ? nil : key
    }
}
