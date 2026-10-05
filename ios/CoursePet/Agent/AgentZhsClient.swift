// MARK: - 智慧树协议客户端（端侧直连）
// 背景：智慧树 passport 挂了阿里云 WAF（DNS CNAME → aligfwaf.com），对数据中心出口
// IP 直接 302 拦截（ECS 实测 0.2s 即 302），服务器代拉整条链路（扫码轮询/登录跳板/
// 拉作业）全废 → 协议整体下沉 iOS 端跑（手机网络出口不被 WAF 拦，与学习通同模式），
// 拉完 push 给服务器入库（/sync/assignments/push）。
// 协议逆向蓝本：v2-backend coursepet-api/app/platforms.py（源自 fuckZHS / zd_utils.py）：
//   ① GET passport.zhihuishu.com/qrCodeLogin/getLoginQrImg —— 出码 {qrToken, img}
//   ② GET /qrCodeLogin/getLoginQrInfo?qrToken= —— status -1未扫/0已扫/1确认(oncePassword)/2过期/3取消
//   ③ GET /login?pwd={oncePassword}&service=... 登录跳板（重定向链落 cookie）
//      + studyservice-api gologin 跳板（考试 API 共用会话，多跳一次是廉价保险）
//   ④ GET onlineservice-api /gateway/f/v1/login/getLoginUserInfo —— 验活取昵称（无需加密）
//   ⑤ POST onlineservice-api queryShareCourseInfo —— secretStr=AES(HOME_KEY) 课程列表
//   ⑥ POST studentexam-api getStudentHomework —— secretStr=AES(EXAM_KEY) flag=1未提交/2已提交
// secretStr：页面 yxyz 函数还原——AES-CBC(固定Key+固定IV)+PKCS7+base64，明文是紧凑 JSON。
// 扫码后的会话 cookie 长期有效（fuckZHS 实测，重扫是低频事件），序列化 JSON 只存手机
// （Keychain 优先 + UserDefaults 兜底），服务器不落智慧树会话。
import CommonCrypto
import Foundation

enum AgentZhsClient {

    struct ZhsError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    struct SyncOutcome {
        var items: [AgentRemoteClient.SyncedAssignmentData] = []
        var complete = true
        var error = ""   // "" == 成功；文案含「失效」时服务器记 auth_failed，提示重新扫码
    }

    // ── 会话存取（cookie JSON + 账号昵称；Keychain 优先，免签名构建降级 UserDefaults）──
    enum Credentials {
        private static let account = "zhsCookie"
        private static let fallbackKey = "agent.zhs.cookie"
        private static let nicknameKey = "agent.zhs.nickname"

        static func saveCookieJSON(_ json: String) {
            if AgentConfigStore.writeExtraKey(json, account: account) { return }
            UserDefaults.standard.set(json, forKey: fallbackKey)
        }

        static func loadCookieJSON() -> String? {
            var blob = AgentConfigStore.readExtraKey(account: account) ?? ""
            if blob.isEmpty { blob = UserDefaults.standard.string(forKey: fallbackKey) ?? "" }
            return blob.isEmpty ? nil : blob
        }

        static func saveNickname(_ name: String) {
            UserDefaults.standard.set(name, forKey: nicknameKey)
        }

        static var nickname: String {
            UserDefaults.standard.string(forKey: nicknameKey) ?? "智慧树用户"
        }

        static func clear() {
            // 写不含有效 JSON 的占位串即等同清除（load 对非 JSON 内容还原失败即视为未绑定），
            // 避免 Keychain 删除失败时残留旧会话
            _ = AgentConfigStore.writeExtraKey("-", account: account)
            UserDefaults.standard.removeObject(forKey: fallbackKey)
            UserDefaults.standard.removeObject(forKey: nicknameKey)
            jar.removeAll()
        }
    }

    // ── 会话：手动 cookie jar（与 ChaoxingClient 同款，实锤 URLSession 自动携带不可靠）──
    // 智慧树登录跳板是重定向链，每跳都会补发 cookie → 挂 RedirectCookieDelegate 在链上
    // 逐跳收 Set-Cookie 并给下一跳重拼 Cookie 头；httpShouldSetCookies=false 关闭系统自动叠加。
    private static var jar: [String: String] = [:]
    private static let session: URLSession = makeSession()

    private static func makeSession() -> URLSession {
        let cfg = URLSessionConfiguration.default
        cfg.httpShouldSetCookies = false
        cfg.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
                + "(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36",
            "Referer": "https://onlineweb.zhihuishu.com/",
            "Accept-Language": "zh-CN,zh;q=0.9",
        ]
        cfg.timeoutIntervalForRequest = 20
        return URLSession(configuration: cfg, delegate: RedirectCookieDelegate.shared, delegateQueue: nil)
    }

    private final class RedirectCookieDelegate: NSObject, URLSessionTaskDelegate {
        static let shared = RedirectCookieDelegate()
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            absorbCookies(from: response)          // 链上每跳的 Set-Cookie 都收进 jar
            var req = request
            req.setValue(cookieHeader(), forHTTPHeaderField: "Cookie")  // 下一跳带上
            completionHandler(req)
        }
    }

    // 跨启动恢复：App 重启后 jar 是空的，从存储的 JSON 还原（进程内有 cookie 则不动）
    private static func restoreCookiesIfNeeded() {
        guard jar.isEmpty, let json = Credentials.loadCookieJSON(),
              let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return }
        for (name, value) in dict where !name.isEmpty && !value.isEmpty {
            jar[name] = value
        }
    }

    private static func cookieSnapshotJSON() -> String? {
        guard !jar.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: jar) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: HTTP 小工具（手动 Cookie 头 + 响应 Set-Cookie 回收）

    private static func absorbCookies(from http: HTTPURLResponse?) {
        guard let http else { return }
        let url = http.url ?? URL(string: "https://passport.zhihuishu.com")!
        for c in HTTPCookie.cookies(withResponseHeaderFields: http.allHeaderFields, for: url)
        where !c.value.isEmpty {
            jar[c.name] = c.value
        }
    }

    private static func cookieHeader() -> String {
        jar.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
    }

    private static func get(_ url: String) async throws -> (code: Int, body: String) {
        var req = URLRequest(url: URL(string: url)!)
        req.setValue(cookieHeader(), forHTTPHeaderField: "Cookie")
        let (data, response) = try await session.data(for: req)
        absorbCookies(from: response as? HTTPURLResponse)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0,
                String(data: data, encoding: .utf8) ?? "")
    }

    private static func formEncode(_ s: String) -> String {
        let allowed = CharacterSet(charactersIn: "-._~").union(.alphanumerics)
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    private static func postForm(_ url: String, params: [String: String]) async throws -> (code: Int, body: String) {
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue(cookieHeader(), forHTTPHeaderField: "Cookie")
        req.httpBody = params.map { "\($0.key)=\(formEncode($0.value))" }
            .joined(separator: "&").data(using: .utf8)
        let (data, response) = try await session.data(for: req)
        absorbCookies(from: response as? HTTPURLResponse)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0,
                String(data: data, encoding: .utf8) ?? "")
    }

    // MARK: AES（照抄 platforms.py _zhs_secret：AES-CBC 固定 Key+IV + PKCS7 + base64）

    private static let zhsIV = "1g3qqdh4jvbskb9x"
    private static let homeKey = "7q9oko0vqb3la20r"   // 学生首页/课程列表（onlineservice-api）
    private static let examKey = "onbfhdyvz8x7otrp"   // 考试/作业（studentexam-api）

    private static func zhsSecret(_ params: [String: Any], key: String) -> String? {
        guard let raw = try? JSONSerialization.data(withJSONObject: params) else { return nil }
        let keyData = Data(key.utf8), ivData = Data(zhsIV.utf8)
        var out = Data(count: raw.count + kCCBlockSizeAES128)
        var outLen = 0
        let status = out.withUnsafeMutableBytes { outPtr in
            raw.withUnsafeBytes { inPtr in
                keyData.withUnsafeBytes { keyPtr in
                    ivData.withUnsafeBytes { ivPtr in
                        CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES),
                                CCOptions(kCCOptionPKCS7Padding),
                                keyPtr.baseAddress, kCCKeySizeAES128, ivPtr.baseAddress,
                                inPtr.baseAddress, inPtr.count,
                                outPtr.baseAddress, outPtr.count, &outLen)
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        out.count = outLen
        return out.base64EncodedString()
    }

    // JSON 字段可能是字符串或数字，统一取成字符串（Python str() 语义）
    private static func strAny(_ v: Any?) -> String? {
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return nil
    }

    private static func status200(_ obj: [String: Any]) -> Bool {
        (strAny(obj["status"]) ?? "") == "200"
    }

    // MARK: 扫码三步（出码 → 轮询 → 确认后登录跳板落会话）

    struct QRCode {
        let token: String
        let imgBase64: String
    }

    /// 生成扫码登录二维码（img 是 PNG 二进制的 base64）
    static func qrCreate() async throws -> QRCode {
        let (code, body) = try await get("https://passport.zhihuishu.com/qrCodeLogin/getLoginQrImg")
        guard let obj = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any],
              let token = strAny(obj["qrToken"]), let img = strAny(obj["img"]) else {
            throw ZhsError(message: "智慧树二维码获取失败（HTTP \(code)，请稍后再试）")
        }
        return QRCode(token: token, imgBase64: img)
    }

    /// 轮询扫码状态：-1 未扫 / 0 已扫 / 1 确认（oncePassword）/ 2 过期 / 3 取消
    static func qrPoll(token: String) async throws -> (status: Int, msg: String, oncePassword: String?) {
        let (code, body) = try await get(
            "https://passport.zhihuishu.com/qrCodeLogin/getLoginQrInfo?qrToken=" + token)
        guard let obj = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any] else {
            throw ZhsError(message: "扫码状态查询异常（HTTP \(code)）")
        }
        return ((obj["status"] as? NSNumber)?.intValue ?? -99,
                strAny(obj["msg"]) ?? "",
                strAny(obj["oncePassword"]))
    }

    /// oncePassword 换正式会话：passport 登录链 → studyservice 跳板 → 验活 → cookie 存手机
    @discardableResult
    static func qrLogin(oncePassword: String) async throws -> String {
        // 登录跳板（URL 格式照抄服务器实测可用的写法，含嵌套 service 参数）
        _ = try await get("https://passport.zhihuishu.com/login?pwd=" + oncePassword
            + "&service=https://onlineservice-api.zhihuishu.com/gateway/f/v1/login/gologin"
            + "?fromurl=https%3A%2F%2Fonlineweb.zhihuishu.com%2F")
        // studyservice 域会话（考试 API 与视频页共用此跳板）
        _ = try await get("https://studyservice-api.zhihuishu.com/login/gologin"
            + "?fromurl=https%3A%2F%2Fstudyh5.zhihuishu.com%2Fapp%2Fstuexamweb.html")
        let nickname = try await verifySession()   // 验活失败在这一步抛错
        Credentials.saveNickname(nickname)
        if let json = cookieSnapshotJSON() { Credentials.saveCookieJSON(json) }
        return nickname
    }

    /// 会话验活：getLoginUserInfo 不需要加密。返回昵称/姓名，失效抛错
    private static func verifySession() async throws -> String {
        let (code, body) = try await get(
            "https://onlineservice-api.zhihuishu.com/gateway/f/v1/login/getLoginUserInfo")
        guard let obj = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any] else {
            throw ZhsError(message: "智慧树登录态检查异常（HTTP \(code)）")
        }
        let result = obj["result"] as? [String: Any] ?? [:]
        let name = ((strAny(result["realName"]) ?? strAny(result["nickName"])) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let uuid = strAny(result["uuid"]) ?? ""
        if name.isEmpty && uuid.isEmpty {
            throw ZhsError(message: "智慧树登录已失效，请重新扫码绑定")
        }
        return name.isEmpty ? "智慧树用户" : String(name.prefix(60))
    }

    // MARK: 拉作业（复用已扫码会话；cookie 失效抛「失效」→ 设置页提示重新扫码）

    /// 登录智慧树并拉全部课程作业（端侧直连，手机网络出口）。
    /// 单课程失败不拖垮整体（complete=false，调用方不据此清理陈旧行）。
    static func sync() async -> SyncOutcome {
        var outcome = SyncOutcome()
        do {
            restoreCookiesIfNeeded()
            _ = try await verifySession()   // 会话死了直接抛「失效」，让用户去重新扫码
            let courses = try await fetchCourses()
            for course in courses.prefix(30) {   // 上限兜底：异常账号课程过多不拖垮
                do {
                    outcome.items.append(contentsOf: try await fetchWorks(course: course))
                } catch {
                    outcome.complete = false   // 单课程失败，整体仍可用但不清理陈旧行
                }
            }
        } catch let e as ZhsError {
            outcome = SyncOutcome(items: [], complete: false, error: e.message)
        } catch {
            outcome = SyncOutcome(items: [], complete: false,
                                  error: "网络异常：\(error.localizedDescription)")
        }
        return outcome
    }

    private struct ZhsCourse {
        let courseId: String
        let recruitId: String
        let name: String
    }

    /// 共享学分课列表（进行中）：queryShareCourseInfo → courseOpenDtos，3 页 × 50 封顶
    private static func fetchCourses() async throws -> [ZhsCourse] {
        var out: [ZhsCourse] = []
        for pageNo in 1...3 {
            guard let secret = zhsSecret(["status": 0, "pageNo": pageNo, "pageSize": 50],
                                         key: homeKey) else {
                throw ZhsError(message: "智慧树参数加密失败")
            }
            let (code, body) = try await postForm(
                "https://onlineservice-api.zhihuishu.com/gateway/t/v1/student/course/share/queryShareCourseInfo",
                params: ["secretStr": secret])
            guard let obj = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any] else {
                throw ZhsError(message: "智慧树课程列表解析失败（HTTP \(code)）")
            }
            guard status200(obj) else {
                throw ZhsError(message: "智慧树课程列表拉取失败（会话可能失效）")
            }
            let rows = (obj["result"] as? [String: Any])?["courseOpenDtos"] as? [[String: Any]] ?? []
            for r in rows {
                guard let cid = strAny(r["courseId"]), let rid = strAny(r["recruitId"]),
                      !cid.isEmpty, !rid.isEmpty else { continue }
                let name = ((strAny(r["courseName"]) ?? strAny(r["courseOpenName"])
                             ?? strAny(r["courseTitle"])) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                out.append(ZhsCourse(courseId: cid, recruitId: rid, name: name))
            }
            if rows.count < 50 { break }
        }
        return out
    }

    private static let timeKeys = ["endTime", "endDateTime", "endDate", "homeworkEndTime",
                                   "examEndTime", "overEndTime", "deadline"]

    /// 截止时间：字段名未实测（作业列表响应未抓过包），按候选键逐一探测；
    /// 兼容 epoch 毫秒/秒与 "yyyy-MM-dd HH:mm" 字符串两种格式（与服务器 _zhs_work_time 对齐）
    private static func workTime(_ row: [String: Any]) -> Date? {
        for key in timeKeys {
            guard let v = row[key] else { continue }
            guard let text = strAny(v) else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed == "0" { continue }
            if let ms = Double(trimmed) {   // 纯数字 → epoch（秒级时间戳容错）
                var interval = ms
                if ms < 1e12 { interval = ms * 1000 }
                return Date(timeIntervalSince1970: interval / 1000)
            }
            let text16 = String(trimmed.prefix(16)).replacingOccurrences(of: "T", with: " ")
            if text16.count == 16, let d = zhsDateFormatter.date(from: text16) { return d }
            return nil   // 首个非空候选键不是合法格式即放弃（与 Python 行为一致）
        }
        return nil
    }

    // 北京时间固定 +8，与服务器 strftime 输出对齐（en_US_POSIX 防地区差异解析翻车）
    private static let zhsDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// 单门课作业列表：flag=1 未提交 + flag=2 已提交两个 tab 各拉一次再合并，
    /// 出现在已提交列表的条目标 isDone（flag 语义来自 Online-Course-Assistant 页面逆向）
    private static func fetchWorks(course: ZhsCourse) async throws -> [AgentRemoteClient.SyncedAssignmentData] {
        var rows: [String: [String: Any]] = [:]
        var submitted: Set<String> = []
        for flag in [1, 2] {
            guard let secret = zhsSecret(["courseId": course.courseId, "flag": flag,
                                          "pageNum": 0, "pageSize": 100,
                                          "recruitId": course.recruitId],
                                         key: examKey) else {
                throw ZhsError(message: "智慧树参数加密失败")
            }
            let (code, body) = try await postForm(
                "https://studentexam-api.zhihuishu.com/studentExam/gateway/t/v1/student/getStudentHomework",
                params: ["secretStr": secret])
            guard let obj = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any] else {
                throw ZhsError(message: "智慧树作业列表解析失败（HTTP \(code)）")
            }
            guard status200(obj) else {
                throw ZhsError(message: "智慧树作业列表拉取失败（status=\(strAny(obj["status"]) ?? "?")）")
            }
            for r in (obj["rt"] as? [String: Any])?["studentHomeworkList"] as? [[String: Any]] ?? [] {
                guard let wid = strAny(r["id"]) ?? strAny(r["examId"]), !wid.isEmpty else { continue }
                rows[wid] = r
                if flag == 2 { submitted.insert(wid) }
            }
        }
        var out: [AgentRemoteClient.SyncedAssignmentData] = []
        for (wid, r) in rows {
            let title = ((strAny(r["examName"]) ?? strAny(r["title"])) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }
            out.append(AgentRemoteClient.SyncedAssignmentData(
                key: "zhihuishu:\(wid)",
                title: String(title.prefix(120)),
                courseName: course.name.isEmpty ? nil : course.name,
                dueDate: workTime(r),
                isDone: submitted.contains(wid)))
        }
        return out
    }
}
