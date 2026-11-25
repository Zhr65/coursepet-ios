// MARK: - 模型服务管理（多 provider 列表 / 切换 / 编辑 / 连通性测试）
// 设计取向：与 AgentSettingsView 一致用 Form（系统设置观感），不做花哨卡片——
// 这一页是"配置"不是"逛"，扫描效率比装饰重要。
import SwiftUI

struct ModelSettingsView: View {
    @State private var providers: [ModelProvider] = []
    @State private var activeId: String?
    @State private var editingProvider: ModelProvider?
    @State private var showPresetMenu = false

    private var serverModeOn: Bool {
        AgentConfigStore.loadServerConfig().isConfigured
    }

    var body: some View {
        Form {
            Section(header: Text("说明"), footer: Text("每个服务商一套配置，Key 只存本机 Keychain。切换「当前」后，对话/拍照识别/画图用的都是这一套。")) {
                HStack(spacing: 10) {
                    Image(systemName: "cpu")
                        .foregroundColor(.indigo)
                    if let p = providers.first(where: { $0.id == activeId }) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("当前：\(p.name)")
                            Text("\(p.model) · \(p.baseURL)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    } else {
                        Text("还没有配置模型服务")
                            .foregroundColor(.secondary)
                    }
                }
                if serverModeOn {
                    Text("⚠️ 服务器模式已启用：对话会走你的后端，这里配置的模型只影响端侧功能（画图/快速调用等）。")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }

            Section(header: Text("模型服务")) {
                ForEach(providers) { provider in
                    providerRow(provider)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                ModelProviderStore.remove(provider.id)
                                reload()
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                }

                Menu {
                    ForEach(Array(ModelProviderStore.presets.enumerated()), id: \.offset) { _, preset in
                        Button(preset.name) {
                            add(preset)
                        }
                    }
                } label: {
                    Label("添加模型服务", systemImage: "plus.circle.fill")
                }

                Button {
                    add(ModelProvider(name: "自定义", baseURL: "", model: ""))
                } label: {
                    Label("手动填写（任意 OpenAI 兼容地址）", systemImage: "square.and.pencil")
                }
            }

            Section {
                Text("地址 404 的常见原因：少了或多写了 /v1。DeepSeek 官方是 /v1 结尾，智谱是 /api/paas/v4，通义是 /compatible-mode/v1。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle("模型服务")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            // 老版本只有一套配置：进来先搬成一条 provider，用户不用重填
            ModelProviderStore.ensureMigrated()
            reload()
        }
        .sheet(item: $editingProvider) { provider in
            ModelProviderEditView(
                provider: provider,
                isNew: !providers.contains(where: { $0.id == provider.id }),
                onSave: { reload() }
            )
        }
    }

    // MARK: - 行

    private func providerRow(_ provider: ModelProvider) -> some View {
        HStack(spacing: 12) {
            Button {
                editingProvider = provider
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(provider.name)
                        .foregroundColor(.primary)
                    if !provider.model.isEmpty {
                        Text(provider.model)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Text(provider.baseURL.isEmpty ? "未填接口地址" : provider.baseURL)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if provider.id == activeId {
                Label("当前", systemImage: "checkmark.circle.fill")
                    .labelStyle(.iconOnly)
                    .foregroundColor(.accentColor)
            } else {
                Button("使用") {
                    ModelProviderStore.setActive(provider.id)
                    reload()
                }
                .font(.caption)
                .buttonStyle(.borderless)
            }
        }
    }

    // MARK: - 动作

    private func add(_ preset: ModelProvider) {
        ModelProviderStore.upsert(preset)
        reload()
        // 添加完立刻进编辑，省一次点击（新预设还没填 Key，不引导去填等于白加）
        editingProvider = preset
    }

    private func reload() {
        providers = ModelProviderStore.all
        activeId = ModelProviderStore.activeId
    }
}

// MARK: - 单个 provider 编辑页

struct ModelProviderEditView: View {
    @Environment(\.dismiss) private var dismiss

    @State var provider: ModelProvider
    let isNew: Bool
    let onSave: () -> Void

    @State private var apiKey = ""
    @State private var testResult: String?
    @State private var testing = false
    @State private var showDeleteConfirm = false

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("基本信息")) {
                    TextField("显示名称（如 我的中转）", text: $provider.name)
                    TextField("接口地址（https://api.deepseek.com/v1）", text: $provider.baseURL)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField("模型名（如 deepseek-chat）", text: $provider.model)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField("图像理解模型（可选，留空跟随主模型）", text: $provider.visionModel)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }

                Section(header: Text("鉴权"),
                        footer: Text("Key 只写本机 Keychain，不上传任何服务器。免签名构建下 Keychain 可能不可用，会自动降级存本地偏好。")) {
                    SecureField("API Key（sk-…）", text: $apiKey)
                }

                Section {
                    Button {
                        Task { await runTest() }
                    } label: {
                        HStack {
                            Label("测试连通", systemImage: "bolt.horizontal.circle")
                            Spacer()
                            if testing { ProgressView() }
                        }
                    }
                    .disabled(testing)

                    if let result = testResult {
                        Text(result)
                            .font(.caption)
                            .foregroundColor(color(for: result))
                    }
                }

                if !isNew {
                    Section {
                        Button("删除这个服务", role: .destructive) {
                            showDeleteConfirm = true
                        }
                    }
                }
            }
            .navigationTitle(isNew ? "添加模型服务" : "编辑模型服务")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                }
            }
            .onAppear {
                if !isNew {
                    apiKey = ModelProviderStore.apiKey(for: provider.id)
                }
            }
            .confirmationDialog("删除后 Key 一并清除，需要重新填写", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                Button("删除", role: .destructive) {
                    ModelProviderStore.remove(provider.id)
                    onSave()
                    dismiss()
                }
                Button("取消", role: .cancel) {}
            }
        }
    }

    // MARK: - 动作

    private func save() {
        var p = provider
        p.name = p.name.trimmingCharacters(in: .whitespacesAndNewlines)
        p.baseURL = p.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        p.model = p.model.trimmingCharacters(in: .whitespacesAndNewlines)
        p.visionModel = p.visionModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if p.name.isEmpty { p.name = p.model.isEmpty ? "未命名" : p.model }
        ModelProviderStore.upsert(p, apiKey: apiKey)
        onSave()
        dismiss()
    }

    @MainActor
    private func runTest() async {
        testing = true
        testResult = nil
        defer { testing = false }
        var p = provider
        p.baseURL = p.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        p.model = p.model.trimmingCharacters(in: .whitespacesAndNewlines)
        testResult = await ModelProviderStore.testConnectivity(provider: p, apiKey: apiKey)
    }

    private func color(for result: String) -> Color {
        if result.hasPrefix("✅") { return .green }
        if result.hasPrefix("⚠️") { return .orange }
        return .red
    }
}
