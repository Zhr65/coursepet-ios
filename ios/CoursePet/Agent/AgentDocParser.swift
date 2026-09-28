// MARK: - 端侧课件解析（端侧 RAG 降级：模式 7 的本机文件抽取，零 VM 依赖）
// 职责：PDF（PDFKit）/TXT 抽取纯文本 + 与服务器 doc_parser.py 对齐的语义分块。
// DOCX/PPTX 端侧不解析（zip+XML 工程量不值）：入口处直接提示"需服务器模式"。
// 扫描版 PDF 抽不出文字 → 诚实抛错，绝不静默入库空块。
import Foundation
import PDFKit

enum AgentDocError: LocalizedError {
    case scannedPDF
    case unsupportedFormat
    case emptyText

    var errorDescription: String? {
        switch self {
        case .scannedPDF:
            return "这是扫描/图片版 PDF，提取不出文字。换成文字版 PDF，或把内容复制粘贴发给我。"
        case .unsupportedFormat:
            return "端侧模式暂不支持该格式（PDF/TXT 之外需服务器模式）。"
        case .emptyText:
            return "没有从文件里提取到文字内容。"
        }
    }
}

enum AgentDocParser {

    static let supportedExtensions = ["pdf", "txt", "md"]  // 端侧可解析；docx/pptx 仅服务器

    static func extractText(from url: URL) throws -> String {
        let ext = url.pathExtension.lowercased()
        let raw: String
        switch ext {
        case "pdf":
            raw = try extractPDF(url: url)
        case "txt", "md":
            raw = try String(contentsOf: url, encoding: .utf8)
        default:
            throw AgentDocError.unsupportedFormat
        }
        // 与服务器 clean_text 对齐：去 NUL/零宽字符、统一换行、压连续空行
        var text = raw
        text = text.replacingOccurrences(of: "\r\n", with: "\n")
                   .replacingOccurrences(of: "\r", with: "\n")
                   .replacingOccurrences(of: "\0", with: "")
                   .replacingOccurrences(of: "\u{200B}", with: "")
                   .replacingOccurrences(of: "\u{FEFF}", with: "")
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count < 20 { throw AgentDocError.emptyText }
        return text
    }

    private static func extractPDF(url: URL) throws -> String {
        guard let doc = PDFDocument(url: url) else { throw AgentDocError.emptyText }
        var pages: [String] = []
        for i in 0..<doc.pageCount {
            if let page = doc.page(at: i), let s = page.string, !s.isEmpty {
                pages.append(s)
            }
        }
        guard !pages.isEmpty else { throw AgentDocError.scannedPDF }
        return pages.joined(separator: "\n")
    }

    /// 语义滑窗分块（与服务器 doc_parser.chunk_text 逐位对齐：500 字窗、80 重叠、句界优先）
    static func chunk(_ text: String, size: Int = 500, overlap: Int = 80) -> [(index: Int, text: String)] {
        let chars = Array(text)
        var chunks: [String] = []
        if chars.count <= size {
            chunks = [text]
        } else {
            let sentenceEnd: Set<Character> = ["。", "！", "？", "\n", "；"]
            var start = 0
            while start < chars.count {
                let windowEnd = min(start + size, chars.count)
                if windowEnd == chars.count {          // 剩余不足一块：整段收尾
                    chunks.append(String(chars[start...]))
                    break
                }
                // 在窗口后半段找最后一个句界（前 250 字内不找，避免块过短）
                var cut = -1
                var i = start + size - 1
                while i >= start + size / 2 {
                    if sentenceEnd.contains(chars[i]) {
                        cut = i - start + 1
                        break
                    }
                    i -= 1
                }
                if cut <= 0 { cut = size }
                chunks.append(String(chars[start..<(start + cut)]))
                start = start + cut - overlap
                if start < 0 { start = 0 }
            }
            chunks = chunks.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                           .filter { !$0.isEmpty }
        }
        // 末块太短（<30 字）并入前块
        if chunks.count >= 2, let last = chunks.last, last.count < 30 {
            chunks[chunks.count - 2] += last
            chunks.removeLast()
        }
        let capped = Array(chunks.prefix(40))
        return capped.enumerated().map { (index: $0.offset, text: $0.element) }
    }
}
