// MARK: - 记忆管理（它记住了你什么，你说了算）
// 服务器模式读写 /agent/memory（PG memory_entries 表，服务器端 Fernet 加密落库）；
// 端侧模式读写本机 UserDefaults（AgentMemoryStore）。支持：
//   分组浏览（按记忆类型）/ 点行编辑 / 左滑删除 / 手动帮它记一条 / 一键清空。
// Muse 式"记忆可视化"，也是隐私出口。删除记忆不会删除聊天记录。
import SwiftUI

struct MemoryManagerView: View {
    @State private var items: [MemoryItem] = []
    @State private var showClearConfirm = false
    @State private var showAddAlert = false
    @State private var newMemoryText = ""
    @State private var editing: MemoryItem?
    @State private var editText = ""
    @State private var errorText = ""
    @State private var cap = 200

    /// 统一行模型（服务器记忆行 id 是 Int，端侧没有 id 用 fact 当标识）
    struct MemoryItem: Identifiable {
        let id: String
        let fact: String
        var kind: String?
        var source: String?
    }

    private var isServerMode: Bool { AgentConfigStore.loadServerConfig().isConfigured }
    private var capText: String { "\(items.count)/\(cap)" }

    /// 按 kind 分组（保持 fact→preference→person→promise 的固定顺序）
    private var groupedItems: [(label: String, items: [MemoryItem])] {
        let order = ["fact", "preference", "person", "promise"]
        var buckets: [String: [MemoryItem]] = [:]
        for item in items { buckets[item.kind ?? "fact", default: []].append(item) }
        return order.compactMap { kind in
            guard let list = buckets[kind], !list.isEmpty else { return nil }
            return (AgentMemoryStore.kindLabel(kind), list)
        }
    }

    var body: some View {
        Group {
            if items.isEmpty && errorText.isEmpty {
                VStack(spacing: 8) {
                    Text("🧠").font(.largeTitle)
                    Text("还没有长期记忆").font(.footnote).foregroundColor(.secondary)
                    Text("聊天里提到的事它觉得值得记，就会出现在这里")
                        .font(.caption2).foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(groupedItems, id: \.label) { group in
                        Section("\(group.label)（\(group.items.count)）") {
                            ForEach(group.items) { item in
                                Button {
                                    editText = item.fact
                                    editing = item
                                } label: {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(item.fact)
                                            .font(.subheadline)
                                            .foregroundColor(.primary)
                                        if let src = sourceLabel(item.source) {
                                            Text(src)
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                }
                            }
                            .onDelete { offsets in
                                delete(group.items, at: offsets)
                            }
                        }
                    }
                    if !errorText.isEmpty {
                        Section { Text(errorText).font(.caption).foregroundColor(.red) }
                    }
                    Section {
                        Button {
                            newMemoryText = ""
                            showAddAlert = true
                        } label: {
                            Label("帮它记一条", systemImage: "plus.circle.fill")
                        }
                        Button(role: .destructive) {
                            showClearConfirm = true
                        } label: {
                            Text("清空全部记忆")
                        }
                    }
                    Section {
                        Text("这些记忆用来让宠物聊天时更懂你（目标、偏好、重要的人等），点一条可以改，删除后下次对话不再注入。删除记忆不会删除聊天记录。\(isServerMode ? "服务器端加密存储，本页为实时列表。" : "只存在这台手机上。")")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .navigationTitle("它记住了什么")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Text(capText).font(.caption).foregroundColor(.secondary)
            }
        }
        .onAppear { reload() }
        .alert("帮它记一条", isPresented: $showAddAlert) {
            TextField("比如：周四下午固定去实验室", text: $newMemoryText)
            Button("记住") {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                if isServerMode {
                    Task { await serverAdd(newMemoryText) }
                } else {
                    AgentMemoryStore.addManual(newMemoryText)
                    reload()
                }
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text("写一句要它长期记住的事")
        }
        .alert("改这条记忆", isPresented: Binding(
            get: { editing != nil },
            set: { if !$0 { editing = nil } })) {
            TextField("记忆内容", text: $editText, axis: .vertical)
            Button("保存") {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                guard let item = editing else { return }
                if isServerMode {
                    Task { await serverEdit(item, to: editText) }
                } else {
                    AgentMemoryStore.update(item.fact, to: editText)
                    reload()
                }
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text("改完下一轮对话生效")
        }
        .alert("清空全部记忆？", isPresented: $showClearConfirm) {
            Button("清空", role: .destructive) { clearAll() }
            Button("取消", role: .cancel) { }
        } message: {
            Text("它会忘记之前记住的所有事，且无法恢复")
        }
    }

    private func sourceLabel(_ source: String?) -> String? {
        switch source {
        case "server": return "服务器同步"
        case "manual": return "你手动记的"
        case "auto": return "聊天里记住的"
        default: return nil   // 服务器列表不标来源（都是服务器提炼的）
        }
    }

    // MARK: 加载
    private func reload() {
        errorText = ""
        if isServerMode {
            Task {
                let server = AgentConfigStore.loadServerConfig()
                guard let token = try? await AgentRemoteClient.ensureToken(
                    baseURL: server.baseURL, username: server.username, password: server.password),
                      let url = URL(string: AgentRemoteClient.trimmedBase(server.baseURL) + "/agent/memory") else {
                    errorText = "连不上服务器"
                    return
                }
                var request = URLRequest(url: url)
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                if let (data, _) = try? await URLSession.shared.data(for: request),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let rows = obj["items"] as? [[String: Any]] {
                    cap = (obj["cap"] as? Int) ?? 300
                    items = rows.compactMap { row in
                        guard let id = row["id"] as? Int, let fact = row["fact"] as? String else { return nil }
                        return MemoryItem(id: String(id), fact: fact,
                                          kind: row["kind"] as? String, source: nil)
                    }
                    // 顺手把镜像刷进本地（管理页秒开 + 切端侧模式注入有货）
                    await AgentMemoryStore.syncServerMirror()
                } else {
                    errorText = "记忆列表拉取失败"
                }
            }
        } else {
            cap = 200
            items = AgentMemoryStore.loadAll().map {
                MemoryItem(id: $0.fact, fact: $0.fact, kind: $0.resolvedKind, source: $0.source)
            }
        }
    }

    // MARK: 删除
    private func delete(_ groupItems: [MemoryItem], at offsets: IndexSet) {
        let targets = offsets.map { groupItems[$0] }
        if isServerMode {
            Task {
                for item in targets { await serverDelete(path: "/agent/memory/\(item.id)") }
                reload()
            }
        } else {
            for item in targets { AgentMemoryStore.remove(item.fact) }
            reload()
        }
    }

    private func clearAll() {
        if isServerMode {
            Task {
                await serverDelete(path: "/agent/memory")
                reload()
            }
        } else {
            AgentMemoryStore.clear()
            items = []
        }
    }

    // MARK: 服务器写操作
    private func serverAdd(_ fact: String) async {
        // POST /agent/memory：服务器端新落一条（fact 类，服务器端加密）
        let server = AgentConfigStore.loadServerConfig()
        guard let token = try? await AgentRemoteClient.ensureToken(
            baseURL: server.baseURL, username: server.username, password: server.password),
              let url = URL(string: AgentRemoteClient.trimmedBase(server.baseURL) + "/agent/memory") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["fact": fact])
        _ = try? await URLSession.shared.data(for: request)
        reload()
    }

    private func serverEdit(_ item: MemoryItem, to newFact: String) async {
        let server = AgentConfigStore.loadServerConfig()
        guard let token = try? await AgentRemoteClient.ensureToken(
            baseURL: server.baseURL, username: server.username, password: server.password),
              let url = URL(string: AgentRemoteClient.trimmedBase(server.baseURL) + "/agent/memory/\(item.id)") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["fact": newFact])
        _ = try? await URLSession.shared.data(for: request)
        reload()
    }

    private func serverDelete(path: String) async {
        let server = AgentConfigStore.loadServerConfig()
        guard let token = try? await AgentRemoteClient.ensureToken(
            baseURL: server.baseURL, username: server.username, password: server.password),
              let url = URL(string: AgentRemoteClient.trimmedBase(server.baseURL) + path) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        _ = try? await URLSession.shared.data(for: request)
    }
}
