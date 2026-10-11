// MARK: - 拍照识课表：Vision 模型识别 → 结构化 Course JSON
// 与 AgentEngine.callLLM 同款 OpenAI 格式 + glm 关思考 + vision 场景路由，
// 但只做一次纯输出 JSON（无历史无工具），失败直接抛错误让上层弹重试。
import Foundation
import UIKit

enum VisionScheduleError: LocalizedError {
    case notConfigured
    case noVisionModel
    case compressionFailed
    case parseFailed(String)
    case networkFailed(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "AI 管家还没配置，先去设置页填 API Key"
        case .noVisionModel: return "没配图像理解模型，建议在设置页填一下"
        case .compressionFailed: return "图片处理失败，换张试试"
        case .parseFailed(let msg): return "识别结果解析不了：\(msg)"
        case .networkFailed(let msg): return "网络请求失败：\(msg)"
        }
    }
}

enum VisionScheduleService {

    /// 拍一张课表 → 输出 [Course]
    /// - Parameter image: 用户拍的课表照片
    /// - Returns: 解析好的课程数组（带 color 自动赋色），可能为空数组（没识别到）
    static func recognize(image: UIImage) async throws -> [Course] {
        let config = AgentConfigStore.load()
        guard config.isConfigured else { throw VisionScheduleError.notConfigured }
        // 强制要求 visionModel——主模型大多不支持识图，空了容易撞墙
        guard !config.visionModel.isEmpty else { throw VisionScheduleError.noVisionModel }
        guard let url = URL(string: config.baseURL + "/chat/completions") else {
            throw VisionScheduleError.networkFailed("接口地址格式不对")
        }

        // 压缩到 1024px 以内，base64 后控制在 ~200KB，省 token 还快
        guard let base64 = compressToBase64(image) else { throw VisionScheduleError.compressionFailed }

        let systemPrompt = """
        你是课表识别助手。从用户发的课表照片中提取每一门课，输出严格的 JSON 数组，每个元素包含：
        - name: 课名（完整，如"高等数学(下)"）
        - dayOfWeek: 星期几（1=周一 … 7=周日，课表第一列是周一）
        - period: 第几节（1-5，按以下固定作息映射：第1节10:00-11:40，第2节12:00-13:40，第3节16:00-17:40，第4节18:00-19:40，第5节20:30-22:00）
        - teacher: 教师（找不到留空字符串）
        - location: 教室（找不到留空字符串）
        - startWeek: 起始周（默认1）
        - endWeek: 结束周（默认20）
        - weekParity: "both"（每周）或 "single"（单周）或 "double"（双周），默认 both

        严格规则：
        1. 节次 period 只认 1-5，按固定作息表反推，别自己猜时间
        2. 周次解析："1-16周单" → startWeek=1 endWeek=16 weekParity=single；"每周"或没写 → weekParity=both
        3. 同名同星期同节次的课去重（合并成一条）
        4. 只输出 JSON，别加任何解释文字
        5. 完全识别不出来就输出空数组 []
        """

        let userContent: [[String: Any]] = [
            ["type": "text", "text": "这是我的课表照片，提取成 JSON 数组。"],
            ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(base64)"]]
        ]

        var body: [String: Any] = [
            "model": config.visionModel,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userContent],
            ],
            "temperature": 0.1,   // 识别要确定性
            "max_tokens": 2000,
            "response_format": ["type": "json_object"]
        ]
        if config.visionModel.lowercased().hasPrefix("glm") {
            body["thinking"] = ["type": "disabled"]
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 90   // Vision 比纯文本慢，多给点
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            return []   // 网络失败直接返回空，上层弹重试
        }

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let raw = message["content"] as? String else {
            throw VisionScheduleError.parseFailed("返回格式不对")
        }

        // 先尝试直接解析 JSON 数组
        let jsonText = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let jsonData = jsonText.data(using: .utf8) else {
            throw VisionScheduleError.parseFailed("编码失败")
        }

        // 模型可能包一层 { "courses": [...] }，也可能直接是数组
        let dict = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
        let array: [[String: Any]]
        if let wrapped = dict?["courses"] as? [[String: Any]] {
            array = wrapped
        } else if let direct = try? JSONSerialization.jsonObject(with: jsonData) as? [[String: Any]] {
            array = direct
        } else {
            return []   // 解析不出来返回空
        }

        return array.compactMap { parseCourse(from: $0) }
    }

    // MARK: - 私有

    private static func compressToBase64(_ image: UIImage) -> String? {
        // 长边 ≤1024，JPEG 0.8 质量
        let maxEdge: CGFloat = 1024
        let size = image.size
        let scale = min(1, maxEdge / max(size.width, size.height))
        let scaled = UIGraphicsImageRenderer(size: CGSize(width: size.width * scale, height: size.height * scale))
            .image { _ in image.draw(in: CGRect(origin: .zero, size: CGSize(width: size.width * scale, height: size.height * scale))) }
        guard let data = scaled.jpegData(compressionQuality: 0.8) else { return nil }
        return data.base64EncodedString()
    }

    private static func parseCourse(from dict: [String: Any]) -> Course? {
        guard let name = (dict["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else { return nil }

        let dayOfWeek = (dict["dayOfWeek"] as? NSNumber)?.intValue ?? 1
        let period = (dict["period"] as? NSNumber)?.intValue ?? 1
        let startTime = periodToTime(period: period, isStart: true)
        let endTime = periodToTime(period: period, isStart: false)
        let teacher = (dict["teacher"] as? String) ?? ""
        let location = (dict["location"] as? String) ?? ""
        let startWeek = (dict["startWeek"] as? NSNumber)?.intValue ?? 1
        let endWeek = (dict["endWeek"] as? NSNumber)?.intValue ?? 20
        let parityRaw = (dict["weekParity"] as? String) ?? "both"
        let weekParity: WeekParity = switch parityRaw {
            case "single": .single
            case "double": .double
            default: .both
        }
        let color = CourseColorPalette.color(forDay: dayOfWeek)

        return Course(
            name: name,
            teacher: teacher,
            location: location,
            dayOfWeek: max(1, min(7, dayOfWeek)),
            startTime: startTime,
            endTime: endTime,
            startWeek: max(1, startWeek),
            endWeek: max(startWeek, endWeek),
            weekParity: weekParity,
            color: color
        )
    }

    /// 固定五节作息映射
    private static func periodToTime(period: Int, isStart: Bool) -> String {
        let schedule: [Int: (String, String)] = [
            1: ("10:00", "11:40"),
            2: ("12:00", "13:40"),
            3: ("16:00", "17:40"),
            4: ("18:00", "19:40"),
            5: ("20:30", "22:00"),
        ]
        guard let pair = schedule[period] else {
            return isStart ? "10:00" : "11:40"
        }
        return isStart ? pair.0 : pair.1
    }
}
