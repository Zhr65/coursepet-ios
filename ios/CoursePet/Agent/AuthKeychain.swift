// MARK: - 登录态存取（Keychain + Token 自动刷新）
// 和 AgentConfigStore 不同：这里存的是登录凭证（access_token + refresh_token），
// 绑定用户身份，删除重装 App 后也不丢（和所有 Keychain 条目一样）。
// "一次登录"的实现：App 启动 → 读 Keychain 的 refresh_token → POST /auth/refresh →
// 拿新 access_token → 存回 Keychain → 进主页；用户全程无感知。
import Foundation
import Security

/// 登录态（从 /auth/* 接口返回后落 Keychain）
struct AuthTokens: Codable {
    var accessToken: String
    var refreshToken: String
    var petName: String
    var loginMethod: String      // "password" / "apple" / "wechat"
    /// access_token 服务端签发时带过期时间，客户端不精确依赖它——
    /// 401 时兜底用 refresh_token 换新；refresh_token 30 天过期由服务端校验。
}

enum AuthStore {

    private static let service = "com.coursepet.auth"
    private static let account = "tokens"

    // MARK: - 存取

    static func save(_ tokens: AuthTokens) {
        guard let data = try? JSONEncoder().encode(tokens) else { return }
        // 先删旧值（Keychain 同 key 重复写入报 duplicate）
        SecItemDelete(baseQuery() as CFDictionary)
        var attrs = baseQuery()
        attrs[kSecValueData as String] = data
        // 首次解锁后可读：App 启动需要读到才能自动登录
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attrs as CFDictionary, nil)
    }

    static func load() -> AuthTokens? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject? = nil
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(AuthTokens.self, from: data)
    }

    static func clear() {
        SecItemDelete(baseQuery() as CFDictionary)
    }

    /// 是否已登录（有 refresh_token 就行——access_token 过期可以续）
    static var isLoggedIn: Bool { load() != nil }

    // MARK: - 自动刷新（网络层 401 时调用，或 App 启动时调用）

    /// 刷新结果：
    ///   ok      = 拿到新 token
    ///   invalid = 服务器明确拒绝（refresh_token 无效/过期）——登录态已清，该回登录页
    ///   offline = 暂时连不上（网络断 / 服务器僵死 / 网关拦截 403 / 5xx）——登录态保留，
    ///             不能因为一次网络抖动把用户踢回登录页（2026-10-09 域名 403 事件的教训）
    enum AuthRefreshResult { case ok, invalid, offline }

    /// 用 refresh_token 换新 access_token。仅 invalid 时清 Keychain（调用方跳登录页）。
    /// 注意：这个函数自己发 HTTP 请求，需要拿到服务器 baseURL——从 AgentConfigStore 读。
    @MainActor
    static func refreshAccessToken(baseURL: String) async -> AuthRefreshResult {
        guard let tokens = load(), !tokens.refreshToken.isEmpty else { return .invalid }
        let url = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines) + "/auth/refresh")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(["refresh_token": tokens.refreshToken])
        do {
            let (data, resp) = try await URLSession.shared.data(for: request)
            guard let http = resp as? HTTPURLResponse else { return .offline }
            struct NewToken: Codable {
                let access_token: String
                let refresh_token: String
                let pet_name: String
                let login_method: String
            }
            if http.statusCode == 200, let nt = try? JSONDecoder().decode(NewToken.self, from: data) {
                save(AuthTokens(accessToken: nt.access_token, refreshToken: nt.refresh_token,
                                petName: nt.pet_name, loginMethod: nt.login_method))
                return .ok
            }
            // 只有服务器明确说"这个 refresh_token 不对"（401）才算登录态失效；
            // 403 多为网关/防火墙拦截（阿里云未备案拦截就是 403），5xx 为服务器异常——都算 offline
            if http.statusCode == 401 {
                clear()
                return .invalid
            }
            return .offline
        } catch {
            return .offline   // 网络不通：不清登录态
        }
    }

    // MARK: - 登出

    @MainActor
    static func logout(baseURL: String) async {
        if let tokens = load(), !tokens.accessToken.isEmpty {
            let url = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines) + "/auth/logout")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
            // 不关心服务器响应，清本地就行
            _ = try? await URLSession.shared.data(for: request)
        }
        clear()
        // 顺手清掉网络层的 token 内存缓存，防止登出后旧 token 还被复用
        AgentRemoteClient.invalidateCachedToken()
    }

    // MARK: - Private

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
