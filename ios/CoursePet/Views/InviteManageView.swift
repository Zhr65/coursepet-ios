// MARK: - 邀请码管理页（设置 → 邀请码）
// 仅在「服务器模式已配置且已登录」时可用。铸码/查看/吊销全程在 App 内完成，
// 不必再 SSH 上服务器跑 ops/make_invite.py。
import SwiftUI
import UIKit

struct InviteManageView: View {
    @State private var invites: [InviteItem] = []
    @State private var isLoading = false
    @State private var isCreating = false
    @State private var errorText: String?
    @State private var justCreated: String?

    // 铸码参数
    @State private var note = ""
    @State private var maxUses = 1
    @State private var expiresDays = 7

    private var server: AgentConfigStore.ServerConfig { AgentConfigStore.loadServerConfig() }
    private var ready: Bool { server.isConfigured && AuthStore.isLoggedIn }

    var body: some View {
        List {
            if !server.isConfigured {
                Section {
                    Label("请先在「AI 管家 → 服务器模式」填好地址并登录，才能发码。",
                          systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            } else if !AuthStore.isLoggedIn {
                Section {
                    Label("当前未登录，请先登录。",
                          systemImage: "person.crop.circle.badge.exclamationmark")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            } else {
                createSection
                if let justCreated { createdCard(justCreated) }
                listSection
                if let errorText {
                    Section {
                        Text(errorText).font(.footnote).foregroundColor(.red)
                    }
                }
            }
        }
        .navigationTitle("邀请码")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    Task { await load() }
                } label: {
                    if isLoading { ProgressView() } else { Image(systemName: "arrow.clockwise") }
                }
                .disabled(isLoading || !ready)
            }
        }
        .task { if ready { await load() } }
    }

    // MARK: 生成
    private var createSection: some View {
        Section {
            TextField("备注（给谁用，便于日后分辨）", text: $note)
            Stepper("可用人数：\(maxUses) 人", value: $maxUses, in: 1...100)
            Picker("有效期", selection: $expiresDays) {
                Text("7 天").tag(7)
                Text("30 天").tag(30)
                Text("永久").tag(0)
            }
            Button {
                Task { await create() }
            } label: {
                HStack {
                    if isCreating { ProgressView().padding(.trailing, 4) }
                    Label(isCreating ? "正在生成…" : "生成邀请码", systemImage: "plus.circle.fill")
                }
            }
            .disabled(isCreating)
        } header: {
            Text("生成新码")
        } footer: {
            Text("生成后会立刻复制到剪贴板，直接发给朋友即可。")
        }
    }

    private func createdCard(_ code: String) -> some View {
        Section {
            HStack {
                Text(code)
                    .font(.system(size: 26, weight: .bold, design: .monospaced))
                    .textSelection(.enabled)
                Spacer()
                Button {
                    UIPasteboard.general.string = code
                } label: {
                    Label("复制", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
            }
        } header: {
            Text("刚刚生成")
        }
    }

    // MARK: 列表
    private var listSection: some View {
        Section("我的邀请码") {
            if invites.isEmpty {
                Text(isLoading ? "加载中…" : "还没有邀请码，点上方「生成邀请码」。")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            } else {
                ForEach(invites) { item in
                    row(item)
                }
            }
        }
    }

    private func row(_ item: InviteItem) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(item.code)
                        .font(.system(size: 17, weight: .semibold, design: .monospaced))
                    badge(item)
                }
                HStack(spacing: 10) {
                    Text("已用 \(item.usedCount)/\(item.maxUses)")
                    Text(expiryText(item.expiresAt))
                    if !item.note.isEmpty { Text(item.note) }
                }
                .font(.caption2)
                .foregroundColor(.secondary)
            }
            Spacer()
            Button {
                UIPasteboard.general.string = item.code
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)

            if item.isUsable {
                Button(role: .destructive) {
                    Task { await revoke(item) }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 2)
    }

    private func badge(_ item: InviteItem) -> some View {
        Text(item.statusText)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background((item.isUsable ? Color.green : Color.gray).opacity(0.18))
            .foregroundColor(item.isUsable ? .green : .secondary)
            .clipShape(Capsule())
    }

    private func expiryText(_ iso: String?) -> String {
        guard let iso, let d = InviteItem.parseUTC(iso) else { return "永不过期" }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return "至 " + f.string(from: d)
    }

    // MARK: 动作
    @MainActor
    private func load() async {
        guard ready else { return }
        isLoading = true
        errorText = nil
        defer { isLoading = false }
        do {
            invites = try await AgentInviteClient.list(baseURL: server.baseURL,
                                                       username: server.username,
                                                       password: server.password)
        } catch {
            errorText = error.localizedDescription
        }
    }

    @MainActor
    private func create() async {
        guard ready else { return }
        isCreating = true
        errorText = nil
        defer { isCreating = false }
        do {
            let item = try await AgentInviteClient.create(
                baseURL: server.baseURL, username: server.username, password: server.password,
                note: note.trimmingCharacters(in: .whitespaces),
                maxUses: maxUses, expiresDays: expiresDays)
            justCreated = item.code
            UIPasteboard.general.string = item.code
            note = ""
            await load()
        } catch {
            errorText = error.localizedDescription
        }
    }

    @MainActor
    private func revoke(_ item: InviteItem) async {
        errorText = nil
        do {
            try await AgentInviteClient.revoke(baseURL: server.baseURL,
                                               username: server.username,
                                               password: server.password,
                                               id: item.id)
            if justCreated == item.code { justCreated = nil }
            await load()
        } catch {
            errorText = error.localizedDescription
        }
    }
}
