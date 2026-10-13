// MARK: - 学校通道判断（XJIT 专属 / 通用拍照）
// 三种状态：.unknown / .generic / .xjit
// 判断优先级：① JWT 标记 > ② 用户手动选 > ④ IP 启发
// 用户可以在校园数据页主动切换 → 写到 UserDefaults，下次启动优先用
import Foundation
import SwiftUI

enum SchoolChannel: String, CaseIterable {
    case unknown = "unknown"     // 未判断
    case generic = "generic"     // 通用：拍照导入
    case xjit = "xjit"           // XJIT：xllite.sayqz.com 一键同步

    var displayName: String {
        switch self {
        case .unknown: return "自动判断"
        case .generic: return "拍照导入"
        case .xjit: return "新疆理工（xllite）"
        }
    }
}

/// 学校通道状态：IP 启发 + 用户覆盖
@MainActor
final class SchoolChannelStore: ObservableObject {
    static let shared = SchoolChannelStore()

    private let kOverrideKey = "schoolChannel.userOverride"
    private let kLastDetectedKey = "schoolChannel.lastDetected"

    @Published var channel: SchoolChannel = .unknown
    @Published var isDetecting: Bool = false
    @Published var detectNote: String = ""

    /// 应用启动时调用：恢复缓存 + 用户覆盖 + JWT 标记
    func bootstrap() async {
        // 1. JWT 标记：如果用户已登录且 JWT 带 xjit 标记 → 强制 .xjit（100% 准）
        if let token = KeychainStore.loadAccessToken(),
           let payload = decodeJWTPayload(token),
           payload["campus"] as? String == "xjit" {
            self.channel = .xjit
            self.detectNote = "已登录：XJIT 账号"
            return
        }

        // 2. 用户手动覆盖：上次主动选了哪个，就用哪个
        if let raw = UserDefaults.standard.string(forKey: kOverrideKey),
           let ch = SchoolChannel(rawValue: raw),
           ch != .unknown {
            self.channel = ch
            self.detectNote = "上次手动选择"
            return
        }

        // 3. 没有任何依据 → IP 启发
        await detectByIP()
    }

    /// 用户手动切换（校园数据页 UI 调用）
    func setChannel(_ ch: SchoolChannel, manual: Bool = true) {
        self.channel = ch
        if manual {
            UserDefaults.standard.set(ch.rawValue, forKey: kOverrideKey)
        }
        UserDefaults.standard.set(ch.rawValue, forKey: kLastDetectedKey)
    }

    /// IP 启发：调免费 ipapi.co，看 ASN 是不是中国教育网 / 城市是不是阿克苏
    private func detectByIP() async {
        self.isDetecting = true
        defer { self.isDetecting = false }

        guard let url = URL(string: "https://ipapi.co/json/") else {
            self.channel = .generic
            self.detectNote = "IP 查询不可用，默认拍照通道"
            return
        }

        var req = URLRequest(url: url)
        req.timeoutInterval = 5   // IP 检测不能阻塞 UI
        req.setValue("CoursePet/1.0", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                self.channel = .generic
                self.detectNote = "IP 查询失败，默认拍照通道"
                return
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                self.channel = .generic
                self.detectNote = "IP 返回格式异常，默认拍照通道"
                return
            }

            // 命中规则（任一满足即视为 XJIT）：
            //   - city 包含 "Akesu"（阿克苏）
            //   - region 包含 "Xinjiang" 且 org 是中国电信 / 移动 / 教育网
            //   - asn 字符串含 "4538" 或 "4534"（中国教育网/中国科技网）
            let city = (json["city"] as? String) ?? ""
            let region = (json["region"] as? String) ?? ""
            let org = (json["org"] as? String) ?? ""
            let asn = (json["asn"] as? String) ?? ""

            let isXjit = city.localizedCaseInsensitiveContains("Akesu")
                || (region.localizedCaseInsensitiveContains("Xinjiang")
                    && (org.contains("China Telecom") || org.contains("China Mobile")
                        || org.contains("Education") || org.contains("CERNET")))
                || asn.contains("4538") || asn.contains("4534")

            if isXjit {
                self.channel = .xjit
                self.detectNote = "IP 提示在新疆，默认 XJIT 通道"
            } else {
                self.channel = .generic
                self.detectNote = "默认拍照通道"
            }
        } catch {
            self.channel = .generic
            self.detectNote = "网络异常，默认拍照通道"
        }
    }

    /// JWT 解码（仅 base64，不验签）
    func decodeJWTPayload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var b64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64.append("=") }
        guard let data = Data(base64Encoded: b64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json
    }
}

/// Keychain 读 token（极简封装，与 AuthKeychain.swift 风格一致）
enum KeychainStore {
    static func loadAccessToken() -> String? {
        // AuthStore.load() 返回的是 AuthTokens 结构体（含 accessToken / refreshToken）
        return AuthStore.load()?.accessToken
    }
}