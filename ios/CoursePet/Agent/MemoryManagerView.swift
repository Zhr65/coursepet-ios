// MARK: - 记忆管理（它记住了你什么，你说了算）
// 服务器模式读写 /agent/memory（PG memories 表）；端侧模式读写本机 UserDefaults。
// 支持单条左滑删除 + 一键清空——Muse 式"记忆可视化"，也是隐私出口。
import SwiftUI

struct MemoryManagerView: View {
    @State private var items: [MemoryItem] = []
    @State private var showClearConfirm = false
    @State private var errorText = ""

    /// 统一行模型（服务器记忆行 id 是 Int，端侧没有 id 用 fact 当标识）
    struct MemoryItem: Identifiable {
        let id: String
        let fact: String
    }

    private var isServerMode: Bool { AgentConfigStore.loadServerConfig().isConfigured }

    init() { }

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
                    if isServerMode {
                        Section("服务器记忆（\(items.count)/50）") {
                            ForEach(items) { item in
                                Text(item.fact)
                                    .font(.subheadline)
                            }
                            .onDelete(perform: deleteServer)
                        }
                    } else {
                        Section("本机记忆（\(items.count)/50）") {
                            ForEach(items) { item in
                                Text(item.fact)
                                    .font(.subheadline)
                            }
                            .onDelete(perform: deleteOnDevice)
                        }
                    }
                    if !errorText.isEmpty {
                        Section { Text(errorText).font(.caption).foregroundColor(.red) }
                    }
                    Section {
                        Button(role: .destructive) {
                            showClearConfirm = true
                        } label: {
                            Text("清空全部记忆")
                        }
                    }
                    Section {
                        Text("这些记忆用来让宠物在聊天时更懂你（如复习计划、兴趣偏好）。删除后下次对话不再注入。")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .navigationTitle("记忆管理")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { reload() }
        .alert("清空全部记忆？", isPresented: $showClearConfirm) {
            Button("清空", role: .destructive) { clearAll() }
            Button("取消", role: .cancel) { }
        } message: {
            Text("它会忘记之前记住的所有事，且无法恢复")
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
                    items = rows.compactMap { row in
                        guard let id = row["id"] as? Int, let fact = row["fact"] as? String else { return nil }
                        return MemoryItem(id: String(id), fact: fact)
                    }
                } else {
                    errorText = "记忆列表拉取失败"
                }
            }
        } else {
            items = AgentMemoryStore.loadAll().map { MemoryItem(id: $0.fact, fact: $0.fact) }
        }
    }

    // MARK: 删除
    private func deleteOnDevice(at offsets: IndexSet) {
        for offset in offsets {
            AgentMemoryStore.remove(items[offset].fact)
        }
        items = AgentMemoryStore.loadAll().map { MemoryItem(id: $0.fact, fact: $0.fact) }
    }

    private func deleteServer(at offsets: IndexSet) {
        let targets = offsets.map { items[$0] }
        Task {
            for item in targets {
                await serverDelete(path: "/agent/memory/\(item.id)")
            }
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
