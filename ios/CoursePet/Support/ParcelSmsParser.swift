// MARK: - 取件短信/文本解析（纯本地正则，零网络零 token）
// 三条入口共用：①记快递弹层剪贴板识别 ②快捷指令 URL scheme 预填 ③AI 管家工具 add_parcel_from_sms
// 设计原则：解析失败返回 nil 由调用方兜底（弹空表单 / 提示用户），绝不猜数据。
import Foundation

enum ParcelSmsParser {
    /// 常见驿站 / 代收点关键词（长词在前，避免"菜鸟"截断"菜鸟驿站"）
    private static let stationKeywords = [
        "菜鸟驿站", "妈妈驿站", "菜鸟", "兔喜生活", "兔喜", "丰巢",
        "京东派", "顺丰驿站", "快递超市", "驿站", "代收点", "快递柜",
    ]

    /// 从文本解析（取件码, 驿站名）；至少识别出取件码才算成功
    static func parse(_ text: String) -> (code: String, station: String?)? {
        let ns = text as NSString
        // 取件码识别：
        // 1) 优先取"取件码/提货码"关键词后面的 X-X-XXXX 三段式
        // 2) 兜底匹配全文首个三段式（排除 2024-10-28 这类日期开头）
        let patterns = [
            #"(?:取件码|提货码)[^0-9]{0,8}(\d{1,4}[-\-－—–]\d{1,4}[-\-－—–]\d{1,6})"#,
            #"(?<!\d)(?!(?:19|20)\d{2}[-－])(\d{1,4}[-\-－—–]\d{1,4}[-\-－—–]\d{1,6})(?!\d)"#,
        ]
        var code: String?
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
                  match.numberOfRanges > 1 else { continue }
            code = ns.substring(with: match.range(at: 1))
                .replacingOccurrences(of: "－", with: "-")
                .replacingOccurrences(of: "—", with: "-")
                .replacingOccurrences(of: "–", with: "-")
            break
        }
        guard let code else { return nil }

        // 驿站名：取出现位置最靠前的关键词，从关键词起向后截取（到标点/空白为止，最长 14 字）
        var station: String?
        var best: (location: Int, keyword: String)?
        for keyword in stationKeywords {
            let range = ns.range(of: keyword)
            if range.location != NSNotFound,
               best == nil || range.location < best!.location {
                best = (range.location, keyword)
            }
        }
        if let best {
            let stopChars: Set<Character> = ["，", "。", ",", "、", "；", ";", "！", "!", "？", "?",
                                             "\n", "\t", " ", "【", "】", "[", "]", "\u{201C}", "\u{201D}"]
            var end = best.location
            while end < ns.length, end - best.location < 14 {
                let ch = Character(ns.substring(with: NSRange(location: end, length: 1)))
                if stopChars.contains(ch) { break }
                end += 1
            }
            let name = ns.substring(with: NSRange(location: best.location, length: end - best.location))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // 括号内的店名保留（如"菜鸟驿站(东门店)"），只在去掉首尾括号后非空才用
            if !name.isEmpty { station = name }
        }
        return (code, station)
    }
}
