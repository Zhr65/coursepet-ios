// MARK: - 课件知识库服务端客户端（文件级 RAG 的服务器链路）
// 对应后端 4 个端点：
//   POST   /sync/docs/file    multipart 上传 → 服务器抽文本分块嵌入
//   GET    /sync/docs/files   文件组 + 散条列表
//   DELETE /sync/docs/file?name=   整文件删除
//   DELETE /sync/docs/{id}    散条删除
// 401 重试、token 复用与 AgentRemoteClient 完全同套（ensureToken 共用缓存）。
import Foundation

struct DocFileGroup: Identifiable, Decodable {
    var name: String
    var chunks: Int
    var createdAt: String?
    var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name, chunks
        case createdAt = "created_at"
    }
}

struct LooseDoc: Identifiable, Decodable {
    var id: Int
    var title: String
    var createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id, title
        case createdAt = "created_at"
    }
}

struct DocLibraryList: Decodable {
    var files: [DocFileGroup]
    var loose: [LooseDoc]
}

/// 上传课件的回执。chunks 是实际入库块数，totalChunks 是整份文件的总块数——
/// 两者不等就说明撞了单文件块数上限（后端截断），UI 必须如实告诉用户，
/// 否则用户以为整本书都进库了，问后面几章 AI 一问三不知。
/// charsTruncated 是另一条独立的截断路径：抽取文本先按字数上限砍，再分块，
/// 砍完块数往往还在上限内，块数看不出异常——这条不单独报，用户就永远不知道后半本没了。
struct DocUploadResult {
    var chunks: Int
    var totalChunks: Int
    var maxChunks: Int
    var truncated: Bool
    var charsTruncated: Bool = false
    var maxChars: Int = 0
}

enum AgentLibraryError: LocalizedError {
    case serverMessage(String)

    var errorDescription: String? {
        if case .serverMessage(let msg) = self { return msg }
        return nil
    }
}

enum AgentLibraryClient {

    // MARK: 上传课件（multipart）—— 返回分块统计
    static func uploadDocFile(baseURL: String, username: String, password: String,
                              displayName: String, fileData: Data,
                              fileExtension: String) async throws -> DocUploadResult {
        // multipart header 按 RFC 只放 ASCII 文件名，中文显示名走 query（服务器原生正确解码）
        let asciiName = "upload_\(Int(Date().timeIntervalSince1970)).\(fileExtension.isEmpty ? "bin" : fileExtension)"
        let boundary = "coursepet.\(UUID().uuidString)"
        var body = Data()
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(asciiName)\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8))
        body.append(fileData)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        let url = try libraryURL(baseURL: baseURL, path: "/sync/docs/file",
                                 query: ["name": displayName])
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        // 100MB 上限 + 服务端 pypdf/docx 解析：60 秒对一本教材的 PDF 完全不够，
        // 超时后客户端报"网络错误"、服务端其实还在写库（重复上传就变成两份课件）。
        // 单位是秒，600s 覆盖"手机上行几 MB/s 传 100MB + 解析 600 页"的最坏情况。
        request.timeoutInterval = 600
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var (data, response) = try await URLSession.shared.upload(for: request, from: body)
        // token 失效：清缓存重新登录再试一次（与 chat() 同款两段式）
        if (response as? HTTPURLResponse)?.statusCode == 401 {
            let fresh = try await AgentRemoteClient.ensureToken(
                baseURL: baseURL, username: username, password: password)
            request.setValue("Bearer \(fresh)", forHTTPHeaderField: "Authorization")
            (data, response) = try await URLSession.shared.upload(for: request, from: body)
        }
        let obj = try decodedObject(data, response: response)
        let chunks = obj["chunks"] as? Int ?? 0
        // 老版本后端不返回 total_chunks / max_chunks：退化成"没截断"，不误报
        let total = obj["total_chunks"] as? Int ?? chunks
        let maxChunks = obj["max_chunks"] as? Int ?? 0
        return DocUploadResult(chunks: chunks, totalChunks: total, maxChunks: maxChunks,
                               truncated: (obj["truncated"] as? Bool) ?? (total > chunks),
                               charsTruncated: (obj["chars_truncated"] as? Bool) ?? false,
                               maxChars: obj["max_chars"] as? Int ?? 0)
    }

    // MARK: 列表（文件组 + 散条）
    static func listDocFiles(baseURL: String, username: String,
                             password: String) async throws -> DocLibraryList {
        let token = try await AgentRemoteClient.ensureToken(baseURL: baseURL, username: username, password: password)
        var request = URLRequest(url: try libraryURL(baseURL: baseURL, path: "/sync/docs/files", query: nil))
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        var (data, response) = try await URLSession.shared.data(for: request)
        if (response as? HTTPURLResponse)?.statusCode == 401 {
            let fresh = try await AgentRemoteClient.ensureToken(
                baseURL: baseURL, username: username, password: password)
            request.setValue("Bearer \(fresh)", forHTTPHeaderField: "Authorization")
            (data, response) = try await URLSession.shared.data(for: request)
        }
        return try JSONDecoder().decode(DocLibraryList.self, from: validated(data, response: response))
    }

    // MARK: 删除整份文件（含全部分块）
    static func deleteDocFile(baseURL: String, username: String, password: String,
                              name: String) async throws {
        let token = try await AgentRemoteClient.ensureToken(baseURL: baseURL, username: username, password: password)
        var request = URLRequest(url: try libraryURL(baseURL: baseURL, path: "/sync/docs/file",
                                                     query: ["name": name]))
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        var (data, response) = try await URLSession.shared.data(for: request)
        if (response as? HTTPURLResponse)?.statusCode == 401 {
            let fresh = try await AgentRemoteClient.ensureToken(
                baseURL: baseURL, username: username, password: password)
            request.setValue("Bearer \(fresh)", forHTTPHeaderField: "Authorization")
            (data, response) = try await URLSession.shared.data(for: request)
        }
        _ = try validated(data, response: response)
    }

    // MARK: 删除散条资料
    static func deleteLooseDoc(baseURL: String, username: String, password: String,
                               id: Int) async throws {
        let token = try await AgentRemoteClient.ensureToken(baseURL: baseURL, username: username, password: password)
        var request = URLRequest(url: URL(string: "\(AgentRemoteClient.trimmedBase(baseURL))/sync/docs/\(id)")!)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        var (data, response) = try await URLSession.shared.data(for: request)
        if (response as? HTTPURLResponse)?.statusCode == 401 {
            let fresh = try await AgentRemoteClient.ensureToken(
                baseURL: baseURL, username: username, password: password)
            request.setValue("Bearer \(fresh)", forHTTPHeaderField: "Authorization")
            (data, response) = try await URLSession.shared.data(for: request)
        }
        _ = try validated(data, response: response)
    }

    // MARK: 内部工具

    /// 带 query 的 URL（percent-encoding 交给 URLComponents，中文安全）
    private static func libraryURL(baseURL: String, path: String,
                                   query: [String: String]?) throws -> URL {
        var components = URLComponents(string: "\(AgentRemoteClient.trimmedBase(baseURL))\(path)")
        if let query {
            components?.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components?.url else { throw URLError(.badURL) }
        return url
    }

    /// 2xx 校验 + 服务器 detail 消息透出（"扫描版无法提取"等文案直达 UI）
    private static func validated(_ data: Data, response: URLResponse) throws -> Data {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) else {
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let detail = obj["detail"] as? String, !detail.isEmpty {
                throw AgentLibraryError.serverMessage(detail)
            }
            throw URLError(.badServerResponse)
        }
        return data
    }

    private static func decodedObject(_ data: Data, response: URLResponse) throws -> [String: Any] {
        let valid = try validated(data, response: response)
        guard let obj = try? JSONSerialization.jsonObject(with: valid) as? [String: Any] else {
            throw URLError(.badServerResponse)
        }
        return obj
    }
}
