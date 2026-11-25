// MARK: - 学校教务凭据存储（端侧，照 ChaoxingClient 的 Keychain 策略）
// 学号 + 教务密码只存手机 Keychain（删除重装仍可回读），服务器不碰凭据。
// 注意：CAS 登录带验证码，无法自动登录——凭据仅作「记住学号」与未来服务端同步预留，
// 实际登录仍在 WebView 里由用户手动输学号/密码/验证码。
import Foundation

enum JiaoWuStore {
    private static let studentAccount = "jiaowuStudent"   // "学号\n密码"

    /// 保存凭据。返回 false = 连 UserDefaults 降级都没存住（Keychain 不可用时
    /// AgentConfigStore 会自动降级写 UserDefaults，所以这里基本只有极端情况会失败）。
    /// 为什么要返回：以前 saveStudent 丢弃写入结果，Keychain 在免签名重签包上
    /// 返回 -34018 时「保存成功」是假的，用户下次打开还是空的。
    @discardableResult
    static func saveStudent(_ sid: String, _ pwd: String) -> Bool {
        let blob = "\(sid)\n\(pwd)"
        _ = AgentConfigStore.writeExtraKey(blob, account: studentAccount)
        // 写完立刻回读校验：写得进才算存住
        return loadStudent()?.sid == sid
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
