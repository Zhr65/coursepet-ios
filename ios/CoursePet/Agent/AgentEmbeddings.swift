// MARK: - 端侧文本向量化（端侧 RAG 的地基层）
// 与服务器端 app/agent/embeddings.py 的哈希嵌入算法逐位对齐：
//   中文字逐字切 + 英文/数字按词切（ICU 正则）→ 单 token + 相邻二元组
//   → MD5 落桶 256 维（桶位=最低字节；符号=倒数第3个hex字符的最低bit）→ L2 归一化
// 对齐的意义：同一文本两端产出相同向量，未来跨端迁移/混检无需重算。
// 无外部依赖、结果确定性可复现；以后换真 embedding 模型只需替换 embed() 一个函数。
import Foundation
import CryptoKit

enum LocalEmbedder {
    static let dimension = 256

    // Swift 的 NSRegularExpression 是 ICU 语法：中文区段用 \x{4E00}-\x{9FFF}
    private static let tokenRegex = try! NSRegularExpression(pattern: "[\\x{4E00}-\\x{9FFF}]|[a-z0-9]+")

    /// 文本 → 256 维 L2 归一化向量（哈希嵌入）
    static func embed(_ text: String) -> [Double] {
        var vec = [Double](repeating: 0, count: dimension)
        let lowered = text.lowercased()
        let ns = lowered as NSString
        let whole = NSRange(location: 0, length: ns.length)
        let tokens = tokenRegex.matches(in: lowered, range: whole).map { ns.substring(with: $0.range) }
        guard !tokens.isEmpty else { return vec }

        var grams = tokens
        if tokens.count > 1 {
            for i in 0..<(tokens.count - 1) {
                grams.append(tokens[i] + tokens[i + 1])  // 二元组：同时抓单字与短语
            }
        }

        for g in grams {
            let hex = Insecure.MD5.hash(data: Data(g.utf8))
                .map { String(format: "%02x", $0) }
                .joined()
            // Python: idx = int(md5hex,16) % 256 —— 等价于十六进制串的最低字节（末2位）
            guard let idx = Int(hex.suffix(2), radix: 16) else { continue }
            // Python: sign = (int(hex,16) >> 8) & 1 —— 等价于倒数第3个hex字符的最低bit
            let nibbleIdx = hex.index(hex.endIndex, offsetBy: -3)
            guard let nibble = hex[nibbleIdx].hexDigitValue else { continue }
            let sign: Double = (nibble & 1) == 1 ? 1.0 : -1.0
            vec[idx] += sign
        }

        let norm = sqrt(vec.reduce(0) { $0 + $1 * $1 })
        guard norm > 0 else { return vec }
        return vec.map { $0 / norm }
    }

    /// 余弦相似度（输入已是 L2 归一化向量 → 点积即余弦，省一次范数计算）
    static func cosine(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count else { return 0 }
        return zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
    }
}
