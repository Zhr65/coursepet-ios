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
                     ? "支持 PDF / Word / PPT / TXT / MD（≤8MB）。整份文件自动分块入库，AI 回答时会检索并标注出自哪个文件哪一段。"
                     : "端侧模式仅支持 PDF / TXT / MD（PPT、Word 需要服务器模式）。资料存本机，重装 App 会清空；服务器模式资料存在服务器不受影响。")
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

        guard url.startAccessingSecurityScopedResource() else {
            errorText = "无法访问所选文件"
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }
        guard let data = try? Data(contentsOf: url) else {
            errorText = "读取文件失败"
            return
        }
        guard !data.isEmpty else {
            errorText = "文件内容为空"
            return
        }

        isBusy = true
        statusText = nil
        errorText = nil

        if isServerMode {
            let cfg = AgentConfigStore.loadServerConfig()
            Task {
                do {
                    let chunks = try await AgentLibraryClient.uploadDocFile(
                        baseURL: cfg.baseURL, username: cfg.username, password: cfg.password,
                        displayName: displayName, fileData: data, fileExtension: ext)
                    await MainActor.run {
                        statusText = "已导入《\(displayName)》· \(chunks) 段入库，可以在聊天里问相关内容了"
                        refreshServer()
                    }
                } catch {
                    await MainActor.run {
                        errorText = friendly(error)
                    }
                }
                await MainActor.run { isBusy = false }
            }
        } else {
            // 端侧：安全作用域关闭后仍要解析，先把文件拷进临时目录再后台处理
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("coursepet_import_\(Int(Date().timeIntervalSince1970)).\(ext.isEmpty ? "txt" : ext)")
            do {
                try data.write(to: tmp, options: .atomic)
            } catch {
                errorText = "读取文件失败：\(error.localizedDescription)"
                return
            }
            Task.detached {
                do {
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
                    try? FileManager.default.removeItem(at: tmp)
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
