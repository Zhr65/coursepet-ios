// MARK: - 端侧课程资料库（端侧 RAG：模式 7 的本机实现，零 VM 依赖）
// 存储：Documents/course_docs.json（个人资料库撑死几百条，文件 + 进程内缓存足够；
//       嵌入向量随文档一起存，检索时内存暴力余弦——256 维 × 100 条 = 毫秒级）
// 检索：LocalEmbedder.embed(query) → 全库余弦排序 → 阈值过滤取 topK
// 与服务器端 RAG 的关系：服务器模式走 pgvector + tools.py；端侧模式走这里。二选一自动跟随。
import Foundation

struct CourseDocItem: Codable, Identifiable {
    var id: String = UUID().uuidString
    var title: String
    var content: String
    var vector: [Double]
    var createdAt: Date = Date()
}

enum AgentDocStore {
    private static var cache: [CourseDocItem]?

    private static var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("course_docs.json")
    }

    static func loadAll() -> [CourseDocItem] {
        if let cache { return cache }
        guard let data = try? Data(contentsOf: fileURL),
              let items = try? JSONDecoder().decode([CourseDocItem].self, from: data) else {
            cache = []
            return []
        }
        cache = items
        return items
    }

    /// 入库一份资料（聊天里"把这段笔记存到资料库" / 以后 OCR 接入都走这里）
    @discardableResult
    static func add(title: String, content: String) -> CourseDocItem {
        let doc = CourseDocItem(
            title: String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80)),
            content: String(content.prefix(4000)),
            vector: LocalEmbedder.embed(title + " " + content)
        )
        var items = loadAll()
        items.insert(doc, at: 0)
        if items.count > 100 { items = Array(items.prefix(100)) }  // 防文件无限膨胀
        persist(items)
        return doc
    }

    /// 检索：返回最相关的 topK 条（相似度低于阈值视为没找到，避免硬凑答案）
    static func search(query: String, topK: Int = 2, minScore: Double = 0.12) -> [(doc: CourseDocItem, score: Double)] {
        let queryVector = LocalEmbedder.embed(query)
        return loadAll()
            .map { (doc: $0, score: LocalEmbedder.cosine(queryVector, $0.vector)) }
            .filter { $0.score >= minScore }
            .sorted { $0.score > $1.score }
            .prefix(topK)
            .map { $0 }
    }

    /// 资料条数（Agent 回答"你存了几份资料"用）
    static var count: Int { loadAll().count }

    static func clear() {
        cache = []
        try? FileManager.default.removeItem(at: fileURL)
    }

    private static func persist(_ items: [CourseDocItem]) {
        cache = items
        if let data = try? JSONEncoder().encode(items) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
