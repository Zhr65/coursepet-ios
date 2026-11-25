// MARK: - 课件知识库管理页（功能 A：文件级 RAG 的 iOS 入口）
// 两种模式自动跟随 AI 管家当前配置（与聊天同一开关 AgentConfigStore）：
//   服务器模式：文件上传 → 服务器抽文本/分块/嵌入/pgvector；列表删除走 AgentLibraryClient
//   端侧模式：  PDF/TXT 本机解析分块进 AgentDocStore（100 条上限）；DOCX/PPTX 提示需服务器
// 呈现两用：聊天页 sheet（presentedAsSheet: true）/ 设置页 NavigationLink push（false）。
import SwiftUI
import UniformTypeIdentifiers

struct CourseLibraryView: View {
    let presentedAsSheet: Bool

    private var isServerMode: Bool {
        AgentConfigStore.loadServerConfig().isConfigured
    }

    @State private var groups: [DocFileGroup] = []
    @State private var loose: [LooseDoc] = []
    @State private var localDocs: [CourseDocItem] = []
    @State private var showImporter = false
    @State private var isBusy = false
    @State private var statusText: String?
    @State private var errorText: String?

    var body: some View {
        Group {
            if presentedAsSheet {
                NavigationStack { content }
            } else {
                content
            }
        }
    }

    private var content: some View {
        List {
            Section {
                // 导入按钮：模式不同可选格式不同
                Button {
                    errorText = nil
                    statusText = nil
                    showImporter = true
                } label: {
                    HStack {
                        if isBusy {
                            ProgressView().padding(.trailing, 4)
                        }
                        Label(isBusy ? "正在处理…" : "导入课件文件",
                              systemImage: "square.and.arrow.down")
                    }
                }
                .disabled(isBusy)

                if let statusText {
                    Text(statusText)
                        .font(.footnote)
                        .foregroundColor(.green)
                }
                if let errorText {
                    Text(errorText)
                        .font(.footnote)
                        .foregroundColor(.red)
                }
            } footer: {
                Text(isServerMode
                     ? "支持 PDF / Word / PPT / TXT / MD（≤100MB，约 600 页文本）。整份文件自动分块入库，AI 回答时会检索并标注出自哪个文件哪一段。大文件上传解析需要时间，别切走页面。"
                     : "端侧模式仅支持 PDF / TXT / MD 且不超过 100 条（PPT、Word 需要服务器模式）。资料存本机，重装 App 会清空；服务器模式资料存在服务器不受影响。")
            }

            if isServerMode {
                // ── 服务器模式：文件组（一份文件 = 一行）──
                Section(header: Text("课件文件")) {
                    if groups.isEmpty {
                        Text("还没有上传过课件文件")
                            .foregroundColor(.secondary)
                            .font(.footnote)
                    }
                    ForEach(groups) { g in
                        HStack {
                            Image(systemName: "doc.text")
                                .foregroundColor(.indigo)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(g.name).lineLimit(1)
                                Text("\(g.chunks) 段")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                deleteServerFile(g)
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }
                }

                Section(header: Text("零散资料")) {
                    if loose.isEmpty {
                        Text("没有散条资料")
                            .foregroundColor(.secondary)
                            .font(.footnote)
                    }
                    ForEach(loose) { d in
                        Text(d.title).lineLimit(1)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    deleteServerLoose(d)
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                    }
                }
            } else {
                // ── 端侧模式：AgentDocStore 全部条目（文件块 title 自带"·第n段"出处）──
                Section(header: Text("本机资料（\(localDocs.count)/100）")) {
                    if localDocs.isEmpty {
                        Text("还没有本机资料。导入 PDF/TXT，或在聊天里让我存笔记。")
                            .foregroundColor(.secondary)
                            .font(.footnote)
                    }
                    ForEach(localDocs) { doc in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(doc.title).lineLimit(1)
                            Text(doc.content.prefix(60) + (doc.content.count > 60 ? "…" : ""))
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                AgentDocStore.remove(id: doc.id)
                                refreshLocal()
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("课件知识库")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if presentedAsSheet {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .onAppear(perform: refresh)
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: allowedTypes,
                      allowsMultipleSelection: false) { result in
            handleImport(result)
        }
    }

    @Environment(\.dismiss) private var dismiss

    // MARK: 模式相关

    // 服务器模式额外放行 docx/pptx（UTType 无预定义常量，动态构造 + compactMap 防 nil）
    private var allowedTypes: [UTType] {
        var types: [UTType] = [.pdf, .plainText]
        if isServerMode {
            let officeTypes = ["org.openxmlformats.wordprocessingml.document",
                               "org.openxmlformats.presentationml.presentation"]
                .compactMap { UTType($0) }
            types.append(contentsOf: officeTypes)
        }
        return types
    }

    private func refresh() {
        if isServerMode {
            refreshServer()
        } else {
            refreshLocal()
        }
    }

    private func refreshLocal() {
        localDocs = AgentDocStore.loadAll()
    }

    private func refreshServer() {
        let cfg = AgentConfigStore.loadServerConfig()
        Task {
            do {
                let list = try await AgentLibraryClient.listDocFiles(
                    baseURL: cfg.baseURL, username: cfg.username, password: cfg.password)
                await MainActor.run {
                    groups = list.files
                    loose = list.loose
                }
            } catch {
                await MainActor.run {
                    errorText = "列表加载失败：\(friendly(error))"
                }
            }
        }
    }

    // MARK: 导入

    private func handleImport(_ result: Result<[URL], Error>) {
        guard let url = (try? result.get())?.first else { return }
        let ext = url.pathExtension.lowercased()
        let displayName = url.lastPathComponent

        isBusy = true
        statusText = "正在读取文件…"
        errorText = nil

        // 上限放开到 100MB 后必须离开主线程读盘：Data(contentsOf:) 在主线程读几十 MB
        // 会把整个页面卡住（iOS 17 上表现为点完导入后界面冻 1-2 秒，用户以为没反应又点一次）。
        // security-scoped 是进程级引用计数，在后台线程 start/stop 同样有效。
        Task.detached {
            let (data, failure) = readScopedFileData(url)
            await MainActor.run {
                if let failure {
                    errorText = failure
                    statusText = nil
                    isBusy = false
                } else if let data {
                    processImported(data, ext: ext, displayName: displayName)
                }
            }
        }
    }

    /// 数据已在内存 → 服务器上传 / 端侧解析。从主线程进入（要读 @State 与 AgentConfigStore）
    private func processImported(_ data: Data, ext: String, displayName: String) {
        if isServerMode {
            let cfg = AgentConfigStore.loadServerConfig()
            statusText = "正在上传并解析《\(displayName)》（取决于文件大小和网速，可能几十秒到几分钟，别切走）…"
            Task {
                do {
                    let res = try await AgentLibraryClient.uploadDocFile(
                        baseURL: cfg.baseURL, username: cfg.username, password: cfg.password,
                        displayName: displayName, fileData: data, fileExtension: ext)
                    await MainActor.run {
                        // 两条独立的截断路径，必须分开说，否则用户永远不知道后半本没进：
                        // ① 字数超 MAX_CHARS：抽取阶段就砍了，块数看起来完全正常（truncated 常为 false）
                        // ② 块数超 MAX_CHUNKS：分块后砍尾部，truncated=true
                        if res.charsTruncated {
                            let cap = res.maxChars > 0 ? "约 \(res.maxChars / 10000) 万字" : "单文件字数上限"
                            statusText = "已导入《\(displayName)》· 只入库了前 \(res.chunks) 段（\(cap)，约一本 600 页教材）。后面的内容没有进去，建议按章节拆成几个文件分别导入。"
                        } else if res.truncated {
                            // 如实说：整份文件 N 段，只入了前 M 段。含糊其辞会让用户
                            // 以为整本书都进了库，问后面几章 AI 答不出来还以为 AI 不行。
                            // maxChunks=0 表示后端是老版本（不回上限值），别显示"上限 0 段"
                            let cap = res.maxChunks > 0 ? "单文件上限 \(res.maxChunks) 段" : "单文件有入库上限"
                            statusText = "已导入《\(displayName)》· 全文 \(res.totalChunks) 段，只入库前 \(res.chunks) 段（\(cap)）。后面的内容建议拆成几个小文件分别导入。"
                        } else {
                            statusText = "已导入《\(displayName)》· \(res.chunks) 段入库，可以在聊天里问相关内容了"
                        }
                        refreshServer()
                    }
                } catch {
                    await MainActor.run { errorText = friendly(error) }
                }
                await MainActor.run { isBusy = false }
            }
        } else {
            statusText = "正在解析《\(displayName)》…"
            // 端侧：后台解析分块（AgentDocParser 不碰 UI）
            Task.detached {
                do {
                    let tmp = FileManager.default.temporaryDirectory
                        .appendingPathComponent("coursepet_import_\(Int(Date().timeIntervalSince1970)).\(ext.isEmpty ? "txt" : ext)")
                    try data.write(to: tmp, options: .atomic)
                    let text = try AgentDocParser.extractText(from: tmp)
                    let chunks = AgentDocParser.chunk(text)
                    try? FileManager.default.removeItem(at: tmp)
                    let (message, ok) = await MainActor.run { () -> (String, Bool) in
                        let remaining = max(0, 100 - AgentDocStore.count)
                        if remaining == 0 {
                            return ("端侧资料库已满（100 条）。删掉一些旧资料再试，大文件建议用服务器模式。", false)
                        }
                        let usable = chunks.prefix(remaining)
                        for chunk in usable {
                            _ = AgentDocStore.add(title: "\(displayName)·第\(chunk.index + 1)段",
                                                  content: chunk.text)
                        }
                        refreshLocal()
                        if usable.count < chunks.count {
                            return ("端侧资料库快满了，只入了前 \(usable.count) 段。大文件建议用服务器模式。", false)
                        }
                        return ("已导入《\(displayName)》· \(usable.count) 段入库（本机）", true)
                    }
                    await MainActor.run {
                        if ok { statusText = message } else { errorText = message }
                        isBusy = false
                    }
                } catch {
                    await MainActor.run {
                        errorText = error.localizedDescription
                        isBusy = false
                    }
                }
            }
        }
    }

    // MARK: 删除

    private func deleteServerFile(_ group: DocFileGroup) {
        let cfg = AgentConfigStore.loadServerConfig()
        Task {
            do {
                try await AgentLibraryClient.deleteDocFile(
                    baseURL: cfg.baseURL, username: cfg.username, password: cfg.password,
                    name: group.name)
                await MainActor.run { refreshServer() }
            } catch {
                await MainActor.run { errorText = friendly(error) }
            }
        }
    }

    private func deleteServerLoose(_ doc: LooseDoc) {
        let cfg = AgentConfigStore.loadServerConfig()
        Task {
            do {
                try await AgentLibraryClient.deleteLooseDoc(
                    baseURL: cfg.baseURL, username: cfg.username, password: cfg.password,
                    id: doc.id)
                await MainActor.run { refreshServer() }
            } catch {
                await MainActor.run { errorText = friendly(error) }
            }
        }
    }

    private func friendly(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

/// 读安全作用域文件（可在后台线程调用）：返回 (数据, 失败原因)，二选一。
/// 为什么不用 Result<Data, String>：Result 的 Failure 必须遵循 Error，String 不满足——
/// 写成 Result<Data, String> 直接编译不过（Codemagic 会报 "type 'String' does not conform to Error"）。
/// 放成文件级函数而不是 View 方法：Task.detached 里只捕 URL，不捕整个 View。
private func readScopedFileData(_ url: URL) -> (Data?, String?) {
    guard url.startAccessingSecurityScopedResource() else {
        return (nil, "无法访问所选文件")
    }
    defer { url.stopAccessingSecurityScopedResource() }
    guard let data = try? Data(contentsOf: url) else {
        return (nil, "读取文件失败")
    }
    guard !data.isEmpty else { return (nil, "文件内容为空") }
    return (data, nil)
}
