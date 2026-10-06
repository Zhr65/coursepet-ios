// MARK: - 学习通协议客户端（端侧直连）
// 背景：学习通对服务器机房出口 IP 全线风控（passport 302 循环 + mooc1 403，
// 与 TLS 指纹/UA 无关），手机网络出口不受影响 → 协议下沉 iOS 端跑，
// 拉完 push 给服务器入库（/sync/assignments/push）。
// 协议逆向蓝本：v2-backend coursepet-api/app/platforms.py（源自 yatori-go-core）：
//   ① POST passport2.chaoxing.com/fanyalogin —— AES-CBC(key=iv="u2oh6Vu^HWe4_AES",
//      PKCS7) 分别加密账号/密码后 base64，表单提交；安卓客户端签名 UA
//      （schild = 固定盐拼接串的 md5）是过风控的关键，缺了会被断连
//   ② GET mooc1-api.chaoxing.com/mycourse/backclazzdata —— channelList 树取开课中课程
//   ③ GET mooc1-api.chaoxing.com/work/task-list?courseId&classId&cpi —— 作业列表 HTML：
//      li[data=跳转URL]，div>p=标题，span[0]=状态，span[-1]=剩余时间（"剩余X天X小时"）
// 凭据只存手机（Keychain 优先 + UserDefaults 兜底，与 AgentConfigStore 同策略），
// 服务器不落学习通密码；拉到的作业本地合并进事务页并上报服务器。
import CommonCrypto
import CryptoKit
import Foundation

enum ChaoxingClient {

    struct ChaoxingError: LocalizedError {
        let message: String
        var sessionExpired = false   // true = 会话失效（可自动重登），false = 真失败（报给用户）
        var errorDescription: String? { message }
    }

    struct SyncOutcome {
        var items: [AgentRemoteClient.SyncedAssignmentData] = []
        var complete = true
        var error = ""   // "" == 成功；文案含「登录/密码/验证码/风控」时服务器记 auth_failed
        var username = ""   // 学习通用户标识（登录后取 uid cookie），上报服务器展示用
    }

    // ── 凭据存取（Keychain 优先；免签名构建 Keychain 不可用时降级 UserDefaults）──
    enum Credentials {
        private static let account = "chaoxingCredential"
        private static let fallbackKey = "agent.chaoxing.credential"

        static func save(user: String, pass: String) {
            let blob = "\(user)\n\(pass)"
            if AgentConfigStore.writeExtraKey(blob, account: account) { return }
            UserDefaults.standard.set(blob, forKey: fallbackKey)
        }

        static func load() -> (username: String, password: String)? {
            var blob = AgentConfigStore.readExtraKey(account: account) ?? ""
            if blob.isEmpty { blob = UserDefaults.standard.string(forKey: fallbackKey) ?? "" }
            guard let nl = blob.firstIndex(of: "\n") else { return nil }
            let user = String(blob[..<nl])
            let pass = String(blob[blob.index(after: nl)...])
            guard !user.isEmpty, !pass.isEmpty else { return nil }
            return (user, pass)
        }

        static func clear() {
            // 写不含换行的占位串即等同清除（load 对无换行内容一律返回 nil），
            // 避免 Keychain 删除失败时残留旧凭据
            _ = AgentConfigStore.writeExtraKey("-", account: account)
            UserDefaults.standard.removeObject(forKey: fallbackKey)
            SessionStore.clear()   // 解绑连持久化会话一起清
        }
    }

    // ── 会话持久化：一次登录管一个月 ──
    // jar 整体存 Keychain（UserDefaults 兜底），同步成功后回存（服务端常在下发响应里
    // 续期 cookie，回存等于续命）；只有会话真失效（被踢回登录页）才重登，平时零登录动作。
    enum SessionStore {
        private static let account = "chaoxingSession"
        private static let fallbackKey = "agent.chaoxing.session"

        static func save(_ jar: [String: String]) {
            guard !jar.isEmpty,
                  let data = try? JSONSerialization.data(withJSONObject: jar),
                  let json = String(data: data, encoding: .utf8) else { return }
            if !AgentConfigStore.writeExtraKey(json, account: account) {
                UserDefaults.standard.set(json, forKey: fallbackKey)
            }
        }

        static func load() -> [String: String]? {
            var json = AgentConfigStore.readExtraKey(account: account) ?? ""
            if json.isEmpty { json = UserDefaults.standard.string(forKey: fallbackKey) ?? "" }
            guard let data = json.data(using: .utf8),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                  !dict.isEmpty else { return nil }
            return dict
        }

        static func clear() {
            _ = AgentConfigStore.writeExtraKey("-", account: account)
            UserDefaults.standard.removeObject(forKey: fallbackKey)
        }
    }

    // ── 会话：手动 cookie jar（requests 同款语义）──
    // 实锤（2026-10-05 真机）：URLSession 独立 HTTPCookieStorage 的自动携带不可靠——
    // fanyalogin 登录成功后请求 mooc1-api 仍被 302 到 passport2 登录页（会话 cookie 没带上）。
    // 改为手动管理：响应里解析 Set-Cookie 存 jar，请求时统一拼 Cookie 头，并关闭
    // httpShouldSetCookies 防止系统再自动叠加一份造成重复。
    private static var jar: [String: String] = [:]
    private static let getSession = makeSession(followsRedirects: true)
    private static let loginSession = makeSession(followsRedirects: false)

    private static func makeSession(followsRedirects: Bool) -> URLSession {
        let cfg = URLSessionConfiguration.default
        cfg.httpShouldSetCookies = false   // Cookie 全权由 jar 手动管理
        cfg.httpAdditionalHeaders = ["User-Agent": mobileUA(), "Accept-Language": "zh_CN"]
        cfg.timeoutIntervalForRequest = 20
        if followsRedirects { return URLSession(configuration: cfg) }
        return URLSession(configuration: cfg, delegate: NoRedirectDelegate.shared, delegateQueue: nil)
    }

    /// 从响应头解析 Set-Cookie 存入 jar（登录和后续响应都可能补发 cookie）
    private static func absorbCookies(from http: HTTPURLResponse?) {
        guard let http else { return }
        var fields: [String: String] = [:]   // allHeaderFields 是 [AnyHashable: Any]，先收窄
        for (key, value) in http.allHeaderFields {
            if let k = key as? String, let v = value as? String { fields[k] = v }
        }
        let url = http.url ?? URL(string: "https://passport2.chaoxing.com")!
        for c in HTTPCookie.cookies(withResponseHeaderFields: fields, for: url)
        where !c.value.isEmpty {
            jar[c.name] = c.value
        }
    }

    private static func cookieHeader() -> String {
        jar.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
    }

    /// 登录请求禁跟随重定向：被 IP 风控时学习通 302 到 passport403.html 且会循环重定向，
    /// 直接掐断并读 Location 精准识别（等价服务器端 post_form follow=False 的语义）
    private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
        static let shared = NoRedirectDelegate()
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)   // 不跟随；302 响应原样返回
        }
    }

    // ── 安卓客户端签名 UA（照抄 platforms.py，schild 是固定盐拼接串的 md5）──
    private static let imei = String((0..<16).map { _ in "0123456789abcdef".randomElement()! })

    private static func md5Hex(_ s: String) -> String {
        Insecure.MD5.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func mobileUA() -> String {
        let device = "MI10"
        let version = "6.7.2"
        let build = "10941_314"
        let schild = md5Hex([
            "(schild:ipL$TkeiEmfy1gTXb2XHrdLN0a@7c^vu)",
            "(device:\(device))",
            "Language/zh_CN",
            "com.chaoxing.mobile/ChaoXingStudy_3_\(version)_android_phone_\(build)",
            "(@Kalimdor)_\(imei)",
        ].joined(separator: " "))
        return [
            "Mozilla/5.0 (Linux; Android 16; \(device) Build/OPM1.171019.019; wv)",
            "AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/71.0.3578.99 Mobile Safari/537.36",
            "(schild:\(schild))",
            "(device:\(device))",
            "Language/zh_CN",
            "com.chaoxing.mobile/ChaoXingStudy_3_\(version)_android_phone_\(build)",
            "(@Kalimdor)_\(imei)",
        ].joined(separator: " ")
    }

    // ── AES-CBC/PKCS7 加密（key 即 iv，与服务器端 _cx_encrypt 一致）──
    private static func cxEncrypt(_ text: String) -> String? {
        let key = Data("u2oh6Vu^HWe4_AES".utf8)
        let input = Data(text.utf8)
        var out = Data(count: input.count + kCCBlockSizeAES128)
        var outLen = 0
        let status = out.withUnsafeMutableBytes { outPtr in
            input.withUnsafeBytes { inPtr in
                key.withUnsafeBytes { keyPtr in
                    CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyPtr.baseAddress, kCCKeySizeAES128, keyPtr.baseAddress,
                            inPtr.baseAddress, inPtr.count,
                            outPtr.baseAddress, outPtr.count, &outLen)
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        out.count = outLen
        return out.base64EncodedString()
    }

    private static func formEncode(_ s: String) -> String {
        let allowed = CharacterSet(charactersIn: "-._~").union(.alphanumerics)
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    // MARK: 登录 → 课程 → 作业

    private static func login(username: String, password: String) async throws {
        guard let uname = cxEncrypt(username), let pass = cxEncrypt(password) else {
            throw ChaoxingError(message: "学习通加密失败，请重试")
        }
        // refer 传预编码串（再过一遍 formEncode 即成双重编码，与 requests 行为一致）
        let body = ["fid": "-1", "uname": uname, "password": pass,
                    "refer": "http%3A%2F%2Fi.mooc.chaoxing.com", "t": "true",
                    "forbidotherlogin": "0", "validate": "", "doubleFactorLogin": "0",
                    "independentId": "0", "independentNameId": "0"]
            .map { "\($0.key)=\(formEncode($0.value))" }
            .joined(separator: "&")
        var req = URLRequest(url: URL(string: "https://passport2.chaoxing.com/fanyalogin")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(body.utf8)
        let (data, response) = try await loginSession.data(for: req)
        let http = response as? HTTPURLResponse
        jar.removeAll()   // 新登录重开 jar，防旧会话串味
        absorbCookies(from: http)
        if let loc = http?.value(forHTTPHeaderField: "Location"), loc.contains("passport403") {
            throw ChaoxingError(message: "学习通风控拦截了当前网络出口，请换个网络或稍后再试")
        }
        let bodyStr = String(data: data, encoding: .utf8) ?? ""
        if bodyStr.contains("很抱歉，您所浏览的页面暂时不能访问") {
            throw ChaoxingError(message: "触发学习通风控，请稍后再试")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ChaoxingError(message: "登录响应异常（HTTP \(http?.statusCode ?? 0)）")
        }
        let ok = (obj["status"] as? Bool == true) || (obj["status"] as? Int == 1)
        if !ok {
            let msg = (obj["msg2"] as? String) ?? (obj["msg"] as? String) ?? ""
            throw ChaoxingError(message: msg.isEmpty ? "用户名或密码错误" : msg)
        }
        NSLog("[Chaoxing] login ok, cookies=%d", jar.count)   // =0 说明响应没发 Set-Cookie，直接可疑
    }

    private static func fetchCourses() async throws -> [(courseId: String, classId: String, cpi: String, name: String)] {
        var req = URLRequest(url: URL(string: "https://mooc1-api.chaoxing.com/mycourse/backclazzdata")!)
        req.setValue(cookieHeader(), forHTTPHeaderField: "Cookie")
        let (data, response) = try await getSession.data(for: req)
        let http = response as? HTTPURLResponse
        absorbCookies(from: http)
        let code = http?.statusCode ?? 0
        let bodyStr = String(data: data, encoding: .utf8) ?? ""
        if code == 403 || bodyStr.contains("输入验证码") {
            throw ChaoxingError(message: "学习通要求验证码，请在学习通 App 里登录一次后再试")
        }
        // 跟随重定向后落点不在 mooc1-api = 会话没带上/已失效（如被 302 到 passport2 登录页）
        if let finalURL = http?.url?.absoluteString, finalURL.contains("passport2.chaoxing.com") {
            throw ChaoxingError(message: "学习通登录会话已失效", sessionExpired: true)
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // 带上响应摘要：绑定失败的报错文案本身就是诊断证据（用户截图即可定位）
            let prefix = bodyStr.prefix(80)
                .replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: "")
            throw ChaoxingError(message: "课程列表解析失败（HTTP \(code)，返回开头：\(prefix)）")
        }
        var out: [(courseId: String, classId: String, cpi: String, name: String)] = []
        var seen = Set<String>()
        for channel in (obj["channelList"] as? [[String: Any]] ?? []) {
            let content = channel["content"] as? [String: Any] ?? [:]
            guard (content["state"] as? Int) == 0 else { continue }   // 结课课程不拉
            for course in ((content["course"] as? [String: Any] ?? [:])["data"] as? [[String: Any]] ?? []) {
                let square = course["courseSquareUrl"] as? String ?? ""
                guard let cid = firstMatch("courseId=(\\d+)", square),
                      let clz = firstMatch("classId=(\\d+)", square) else { continue }
                guard seen.insert(clz).inserted else { continue }
                let cpi: String
                if let n = channel["cpi"] as? NSNumber { cpi = n.stringValue }
                else if let s = channel["cpi"] as? String { cpi = s }
                else { cpi = "" }
                let name = (course["name"] as? String ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                out.append((cid, clz, cpi, name))
                break   // 每个频道只取一门课（与 Python 蓝本一致）
            }
        }
        return out
    }

    private static func fetchWorks(course: (courseId: String, classId: String, cpi: String, name: String)) async throws -> [(key: String, title: String, statusText: String, remainText: String)] {
        let url = URL(string: "https://mooc1-api.chaoxing.com/work/task-list"
            + "?courseId=\(course.courseId)&classId=\(course.classId)&cpi=\(course.cpi)")!
        var req = URLRequest(url: url)
        req.setValue(cookieHeader(), forHTTPHeaderField: "Cookie")
        let (data, response) = try await getSession.data(for: req)
        absorbCookies(from: response as? HTTPURLResponse)
        if let code = (response as? HTTPURLResponse)?.statusCode, code >= 400 {
            throw ChaoxingError(message: "作业列表拉取失败（HTTP \(code)）")
        }
        // 同 fetchCourses：落点被 302 到 passport2 = 会话失效
        if let finalURL = (response as? HTTPURLResponse)?.url?.absoluteString,
           finalURL.contains("passport2.chaoxing.com") {
            throw ChaoxingError(message: "学习通登录会话已失效，请解绑后重新绑定")
        }
        return parseWorksHTML(String(data: data, encoding: .utf8) ?? "")
    }

    /// 拉全部课程的作业（端侧直连，手机网络出口）。
    /// 会话复用优先：jar 为空先读持久化会话，直接拉列表；只有会话真失效才重登一次。
    /// 单课程失败不拖垮整体（complete=false，调用方不据此清理陈旧行）。
    static func sync(username: String, password: String) async -> SyncOutcome {
        var outcome = SyncOutcome()
        do {
            if jar.isEmpty, let saved = SessionStore.load() { jar = saved }
            var courses: [(courseId: String, classId: String, cpi: String, name: String)]
            do {
                courses = try await fetchCourses()   // 会话还有效 = 不登录
            } catch let e as ChaoxingError where e.sessionExpired {
                try await login(username: username, password: password)   // 兜底重登一次
                courses = try await fetchCourses()
            }
            outcome = try await collectOutcome(courses: courses)
            outcome.username = username
            SessionStore.save(jar)   // 回存刷新过的会话，越用越不容易过期
        } catch let e as ChaoxingError {
            outcome = SyncOutcome(items: [], complete: false, error: e.message)
        } catch {
            outcome = SyncOutcome(items: [], complete: false,
                                  error: "网络异常：\(error.localizedDescription)")
        }
        return outcome
    }

    /// 单课程循环抽公共：sync(账密) 与 syncAfterQR(扫码) 共用
    private static func collectOutcome(courses: [(courseId: String, classId: String, cpi: String, name: String)]) async throws -> SyncOutcome {
        var outcome = SyncOutcome()
        let now = Date()
        for course in courses.prefix(30) {   // 上限兜底：异常账号课程过多不拖垮
            do {
                for w in try await fetchWorks(course: course) {
                    let done = doneHints.contains { w.statusText.contains($0) }
                    let due: Date?
                    if let sec = parseRemainSeconds(w.remainText) {
                        // 剩余 ≤0（含"剩余0天0小时"）= 已过期/今天就到期的边界：归入今天之前，
                        // 让「只同步今天起的作业」规则把它挡住，防旧作业天天挂在列表
                        due = sec > 0 ? now.addingTimeInterval(sec) : now.addingTimeInterval(-86400)
                    } else {
                        due = nil   // 解析不出截止时间的同步作业不显示（多为历史旧账，无法判定新旧）
                    }
                    outcome.items.append(AgentRemoteClient.SyncedAssignmentData(
                        key: w.key,
                        title: w.title,
                        courseName: course.name.isEmpty ? nil : course.name,
                        dueDate: due,
                        isDone: done))
                }
            } catch {
                outcome.complete = false   // 单课程失败，整体仍可用但不清理陈旧行
            }
        }
        return outcome
    }

    // MARK: 扫码登录（端侧直连；学习通风控只拦机房 IP，手机走网页扫码通道畅通）
    // 协议照抄 passport2 登录页 JS（2026-10-06 抓包实锤）：
    //   GET /login?newversion=true 拿会话 → POST /refreshQRCode 出 {enc,uuid}
    //   二维码图 = /createqr?uuid=…&fid=-1 官方直出（App 一定认）
    //   POST /getauthstatus/v2 轮询：status=true 成功落会话 cookie；
    //   type "4"已扫 / "6"取消 / "2""7"失效（type 是字符串，防御性兼容数字）
    struct QRSession { let enc: String; let uuid: String }

    enum QRState: Equatable {
        case waiting            // 未扫
        case scanned            // 已扫，等手机上点确认
        case confirmed          // 登录成功，会话已进 jar
        case expired(String)    // 失效/被取消 → 界面出「重新获取」
        case failed(String)     // 网络/响应异常
    }

    private static let passportUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_7 like Mac OS X) AppleWebKit/605.1.15"

    static func qrCreate() async throws -> QRSession {
        // ① 访问登录页暖会话（refreshQRCode 依赖登录页发的 cookie）
        var warm = URLRequest(url: URL(string: "https://passport2.chaoxing.com/login?fid=&newversion=true")!)
        warm.setValue(passportUA, forHTTPHeaderField: "User-Agent")
        let (_, warmResp) = try await getSession.data(for: warm)
        absorbCookies(from: warmResp as? HTTPURLResponse)
        // ② 出码
        var req = URLRequest(url: URL(string: "https://passport2.chaoxing.com/refreshQRCode")!)
        req.httpMethod = "POST"
        req.setValue(passportUA, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await getSession.data(for: req)
        absorbCookies(from: response as? HTTPURLResponse)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let enc = obj["enc"] as? String, let uuid = obj["uuid"] as? String else {
            throw ChaoxingError(message: "获取二维码失败，请重试")
        }
        return QRSession(enc: enc, uuid: uuid)
    }

    /// 官方 createqr 直出的二维码图（jpeg）
    static func qrImageURL(_ s: QRSession) -> URL {
        URL(string: "https://passport2.chaoxing.com/createqr?uuid=\(s.uuid)&fid=-1")!
    }

    /// 轮询一次；登录成功时 Set-Cookie 落 jar（同浏览器语义：登录页 cookie 全程保留）
    static func qrPoll(_ s: QRSession) async throws -> QRState {
        let body = ["enc": s.enc, "uuid": s.uuid,
                    "doubleFactorLogin": "0", "forbidotherlogin": "1"]
            .map { "\($0.key)=\(formEncode($0.value))" }
            .joined(separator: "&")
        var req = URLRequest(url: URL(string: "https://passport2.chaoxing.com/getauthstatus/v2")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue(passportUA, forHTTPHeaderField: "User-Agent")
        req.httpBody = Data(body.utf8)
        let (data, response) = try await getSession.data(for: req)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failed("轮询响应异常")
        }
        let ok = obj["status"] as? Bool == true
            || obj["status"] as? Int == 1
            || (obj["status"] as? String) == "true"
        if ok {
            absorbCookies(from: response as? HTTPURLResponse)
            NSLog("[Chaoxing] QR login ok, cookies=%d uid=%@", jar.count, jar["uid"] ?? "?")
            return .confirmed
        }
        let type = (obj["type"] as? String) ?? ((obj["type"] as? Int).map(String.init) ?? "")
        let mes = obj["mes"] as? String ?? ""
        switch type {
        case "4": return .scanned
        case "6": return .expired("已在手机上取消，请重新获取")
        case "2", "7": return .expired(mes.isEmpty ? "二维码已过期，请重新获取" : mes)
        default: return .waiting
        }
    }

    /// 扫码确认后：会话已进 jar，直接拉课程+作业（不走登录）
    static func syncAfterQR() async -> SyncOutcome {
        var outcome = SyncOutcome()
        do {
            let courses = try await fetchCourses()
            outcome = try await collectOutcome(courses: courses)
            outcome.username = jar["uid"].map { "uid\($0)" } ?? "学习通用户"
            SessionStore.save(jar)   // 扫码会话同样持久化：一次扫码管一个月
        } catch let e as ChaoxingError {
            outcome = SyncOutcome(items: [], complete: false, error: e.message)
        } catch {
            outcome = SyncOutcome(items: [], complete: false,
                                  error: "网络异常：\(error.localizedDescription)")
        }
        return outcome
    }

    private static let doneHints = ["已提交", "已完成", "已批阅", "已过期", "已结束"]

    // MARK: 解析（正则与 Python 蓝本逐条对齐，便于行为一致）

    private static let reLI = try! NSRegularExpression(
        pattern: "<li[^>]*\\bdata=\"([^\"]+)\"[^>]*>(.*?)</li>", options: [.dotMatchesLineSeparators])
    private static let reP = try! NSRegularExpression(
        pattern: "<p[^>]*>(.*?)</p>", options: [.dotMatchesLineSeparators])
    private static let reSpan = try! NSRegularExpression(
        pattern: "<span[^>]*>(.*?)</span>", options: [.dotMatchesLineSeparators])
    private static let reTag = try! NSRegularExpression(pattern: "<[^>]+>")

    private static func firstMatch(_ pattern: String, _ text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    private static func replaceRegex(_ re: NSRegularExpression, _ text: String, template: String) -> String {
        re.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    private static func unescapeHTML(_ s: String) -> String {
        var r = s
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
        // 数字实体 &#123;：倒序替换防区间位移
        let re = try! NSRegularExpression(pattern: "&#(\\d+);")
        let ns = NSMutableString(string: r)
        for m in re.matches(in: r, range: NSRange(r.startIndex..., in: r)).reversed() {
            guard m.numberOfRanges > 1, let rr = Range(m.range(at: 1), in: r),
                  let code = UInt32(String(r[rr])), let scalar = Unicode.Scalar(code) else { continue }
            ns.replaceCharacters(in: m.range, with: String(Character(scalar)))
        }
        return ns as String
    }

    private static func parseWorksHTML(_ body: String) -> [(key: String, title: String, statusText: String, remainText: String)] {
        var works: [(key: String, title: String, statusText: String, remainText: String)] = []
        for m in reLI.matches(in: body, range: NSRange(body.startIndex..., in: body)) {
            guard m.numberOfRanges > 2,
                  let rawRange = Range(m.range(at: 1), in: body),
                  let innerRange = Range(m.range(at: 2), in: body) else { continue }
            let rawURL = String(body[rawRange])
            let inner = String(body[innerRange])
            guard rawURL.contains("taskrefId") || rawURL.contains("workId") else { continue }  // 跳过章节任务等
            let innerNS = NSRange(inner.startIndex..., in: inner)
            let spans = reSpan.matches(in: inner, range: innerNS).compactMap { sm -> String? in
                guard sm.numberOfRanges > 1, let sr = Range(sm.range(at: 1), in: inner) else { return nil }
                return unescapeHTML(replaceRegex(reTag, String(inner[sr]), template: ""))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            var hasP = false
            var title = ""
            if let pm = reP.firstMatch(in: inner, range: innerNS), pm.numberOfRanges > 1,
               let pr = Range(pm.range(at: 1), in: inner) {
                title = unescapeHTML(replaceRegex(reTag, String(inner[pr]), template: ""))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                hasP = true
            }
            if title.isEmpty { title = spans.first ?? "" }
            let statusText = spans.count > (hasP ? 1 : 0) ? spans[0] : ""
            let remainText = spans.count > 1 ? spans[spans.count - 1] : ""
            // 幂等键：taskrefId 优先，退化用 URL 指纹
            let extKey = firstMatch("taskrefId=(\\d+)", unescapeHTML(rawURL))
                ?? String(md5Hex(rawURL).prefix(16))
            works.append(("chaoxing:\(extKey)", String(title.prefix(120)), statusText, remainText))
        }
        return works
    }

    private static func parseRemainSeconds(_ text: String) -> TimeInterval? {
        let d = firstMatch("(\\d+)\\s*天", text).flatMap { Int($0) } ?? 0
        let h = firstMatch("(\\d+)\\s*(?:小?时)", text).flatMap { Int($0) } ?? 0
        let mi = firstMatch("(\\d+)\\s*分", text).flatMap { Int($0) } ?? 0
        guard d > 0 || h > 0 || mi > 0 else { return nil }
        return TimeInterval(d * 86400 + h * 3600 + mi * 60)
    }
}
