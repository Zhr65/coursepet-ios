// MARK: - xllite 校园数据集成客户端
// 同校同学做的"新理 Lite"项目（xjit.sayqz.com/xllite.sayqz.com）反向协议
// 集成方式（证据等级 L2，来自 libapp.so 字符串扫描 + /api/v1/openapi.json）：
//   1. App 直发 xllite 服务器拿 accessToken（学号+密码只进 Keychain/EncryptedSharedPrefs）
//   2. App 用 accessToken 调 /api/v1/run 取 jw.schedule（或其他 feature）
//   3. App 解析 JSON 转 CoursePet 课表模型
//   4. App 推 CoursePet 后端 /campus/sync 入库
//
// 后端永远碰不到学号+密码 —— 风险全在 xllite.sayqz.com（他服务器，已公开）。
// 安全性设计：
//   - 学号+密码只在 Keychain，App 启动不持久化明文（每次让用户输或从 Keychain 读）
//   - accessToken 短期缓存（他那边 /auth/refresh 频率受控，不滥用）
//   - 推 CoursePet 后端时只传 student_id + 课表内容，绝不带密码字段
//
// 与现有 AgentRemoteClient 是兄弟关系，不复用（一个是 CoursePet 后端，一个是 xllite）
import Foundation

enum XlliteClient {

    // MARK: 错误
    enum XlliteError: Error, LocalizedError {
        case http(Int, String)        // 状态码 + 错误描述
        case badResponse
        case unauthorized

        var errorDescription: String? {
            switch self {
            case .http(let code, let msg): return "xllite HTTP \(code): \(msg)"
            case .badResponse: return "xllite 响应格式错误"
            case .unauthorized: return "xllite 鉴权失败（学号/CAS 密码错）"
            }
        }
    }

    // MARK: 数据模型（与 /api/v1/run jw.schedule 响应对齐）
    struct XlliteCourse: Codable {
        let day: String           // "星期一"
        let slot: String          // "第一大节"
        let title: String
        let teacher: String?
        let weeks: String?        // "1-16周"
        let sections: String?     // "1-2节"
        let location: String?

        // 允许部分字段缺失
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.day = try c.decode(String.self, forKey: .day)
            self.slot = try c.decode(String.self, forKey: .slot)
            self.title = try c.decode(String.self, forKey: .title)
            self.teacher = try c.decodeIfPresent(String.self, forKey: .teacher)
            self.weeks = try c.decodeIfPresent(String.self, forKey: .weeks)
            self.sections = try c.decodeIfPresent(String.self, forKey: .sections)
            self.location = try c.decodeIfPresent(String.self, forKey: .location)
        }
    }

    struct XlliteScheduleData: Codable {
        let term: String
        let termLabel: String?
        let courses: [XlliteCourse]
    }

    private struct XlliteRunResponse: Decodable {
        let ok: Bool?
        let data: XlliteScheduleData?
    }

    private struct XlliteLoginResponse: Decodable {
        let accessToken: String
        let ok: Bool?

        enum CodingKeys: String, CodingKey {
            case accessToken = "accessToken"
            case ok
        }
    }

    // MARK: 登录（学号+CAS 密码 → accessToken）
    /// baseURL 形如 "https://xllite.sayqz.com"（末尾不带 /）
    static func login(baseURL: String, username: String, password: String) async throws -> String {
        let url = URL(string: "\(baseURL)/api/v1/auth/login")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 20

        let body: [String: Any] = [
            "username": username,
            "password": password,
            "remember": false
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            if code == 401 || code == 403 { throw XlliteError.unauthorized }
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw XlliteError.http(code, msg)
        }

        guard let decoded = try? JSONDecoder().decode(XlliteLoginResponse.self, from: data) else {
            throw XlliteError.badResponse
        }
        return decoded.accessToken
    }

    // MARK: 拉课表
    /// 调 /api/v1/run {accessToken, feature:"jw.schedule", params:{term?}}
    /// term 形如 "2026-2027-1"；nil = 教务默认当前学期
    static func fetchSchedule(baseURL: String, token: String, term: String? = nil) async throws -> XlliteScheduleData {
        let url = URL(string: "\(baseURL)/api/v1/run")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 30

        var params: [String: Any] = [:]
        if let t = term, !t.isEmpty { params["term"] = t }

        let body: [String: Any] = [
            "accessToken": token,
            "feature": "jw.schedule",
            "params": params
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw XlliteError.http(code, msg)
        }
        guard let decoded = try? JSONDecoder().decode(XlliteRunResponse.self, from: data),
              let schedule = decoded.data else {
            throw XlliteError.badResponse
        }
        return schedule
    }

    // MARK: 推 CoursePet 后端（入校园库）
    /// 把 xllite 解析后的课表转成后端 CampusSyncIn 体，调 POST /campus/sync
    /// - Parameters:
    ///   - coursepetBaseURL: 形如 "https://api.coursepet.app"
    ///   - coursepetToken: 用户在 CoursePet 的 JWT（现有登录态）
    ///   - studentId: xllite 返的学号
    static func pushToCoursePet(
        coursepetBaseURL: String,
        coursepetToken: String,
        studentId: String,
        schedule: XlliteScheduleData
    ) async throws -> Int {
        let url = URL(string: "\(coursepetBaseURL)/campus/sync")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(coursepetToken)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 30

        let courses: [[String: Any]] = schedule.courses.map { c in
            var dict: [String: Any] = [
                "student_id": studentId,
                "term": schedule.term,
                "day": c.day,
                "slot": c.slot,
                "title": c.title,
            ]
            if let v = c.teacher, !v.isEmpty { dict["teacher"] = v }
            if let v = c.weeks, !v.isEmpty { dict["weeks"] = v }
            if let v = c.sections, !v.isEmpty { dict["sections"] = v }
            if let v = c.location, !v.isEmpty { dict["location"] = v }
            return dict
        }

        let body: [String: Any] = [
            "student_id": studentId,
            "term": schedule.term,
            "courses": courses
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw XlliteError.http(code, msg)
        }
        // 返 {"deleted":true, "inserted":N}
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let n = obj["inserted"] as? Int {
            return n
        }
        return 0
    }

    // MARK: 拉 CoursePet 后端已存课表（多端同步用）
    /// 拿当前用户在 CoursePet 后端存的所有 xllite 课表
    static func listCoursePetCampus(
        coursepetBaseURL: String,
        coursepetToken: String,
        term: String? = nil
    ) async throws -> [[String: Any]] {
        var urlStr = "\(coursepetBaseURL)/campus/courses"
        if let t = term, !t.isEmpty {
            urlStr += "?term=\(t.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? t)"
        }
        let url = URL(string: urlStr)!
        var req = URLRequest(url: url)
        req.setValue("Bearer \(coursepetToken)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw XlliteError.http(code, "") }
        return (try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
    }
}
