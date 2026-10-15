// MARK: - 学校教务凭据存储（端侧，照 ChaoxingClient 的 Keychain 策略）
// 学号 + 教务密码只存手机 Keychain（删除重装仍可回读），服务器不碰凭据。
// 注意：CAS 登录带验证码，无法自动登录——凭据仅作「记住学号」与未来服务端同步预留，
// 实际登录仍在 WebView 里由用户手动输学号/密码/验证码。
import Foundation

enum JiaoWuStore {
    private static let studentAccount = "jiaowuStudent"   // "学号\n密码"

    static func saveStudent(_ sid: String, _ pwd: String) {
        let blob = "\(sid)\n\(pwd)"
        _ = AgentConfigStore.writeExtraKey(blob, account: studentAccount)
    }

    static func loadStudent() -> (sid: String, pwd: String)? {
        guard let blob = AgentConfigStore.readExtraKey(account: studentAccount),
              let nl = blob.firstIndex(of: "\n") else { return nil }
        let sid = String(blob[..<nl])
        let pwd = String(blob[blob.index(after: nl)...])
        guard !sid.isEmpty else { return nil }
        return (sid, pwd)
    }

    static func hasStudent() -> Bool {
        loadStudent() != nil
    }

    static func clearStudent() {
        _ = AgentConfigStore.writeExtraKey("-", account: studentAccount)
    }
}
