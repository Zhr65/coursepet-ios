// MARK: - 邀请码管理页（仅管理员可见，SettingsView 内 sheet 弹出）
// 列表 + 生成弹窗 + 复制/分享 + 撤销。
// 设计选择：不用系统 alert（与设置页 exportTipText 同款：iOS 26 上呈现路径有崩溃嫌疑）
//          改用 .alert(_:isPresented:) 仅用于最关键的「复制成功」一行确认。
import SwiftUI
import UIKit

struct InviteManagerView: View {

    @Environment(\.dismiss) private var dismiss
    @State private var invites: [InviteInfo] = []
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var showCreateSheet = false
    @State private var copiedTip: String?    // 行内提示"已复制"
    @State private var revokeCandidate: InviteInfo?

    private var baseURL: String {
        AgentConfigStore.loadServerConfig().baseURL
    }

    var body: some View {
        NavigationStack {
            ZStack {
                GlassBackdrop()

                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        // 顶部说明
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "person.2.badge.gearshape")
                                .foregroundColor(.orange)
                            Text("每个邀请码默认 7 天有效、1 人 1 码。给同学码子后，对方在登录页「注册」时填这个码即可。")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 8)

                        if loading && invites.isEmpty {
                            ProgressView().padding()
                        }

                        if let err = errorMessage {
                            Text(err).font(.footnote).foregroundColor(.red)
                                .padding(.horizontal, 16)
                        }

                        if invites.isEmpty && !loading {
                            Text("还没有邀请码，点右上角 + 生成第一个")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 40)
                        }

                        ForEach(invites) { inv in
                            inviteRow(inv)
                        }
                    }
                }
                .refreshable { await refresh() }
            }
            .navigationTitle("邀请码管理")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showCreateSheet = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showCreateSheet) {
                CreateInviteSheet(baseURL: baseURL) { newInvite in
                    invites.insert(newInvite, at: 0)
                }
            }
            .alert(item: Binding(
                get: { revokeCandidate.map { RevokeTarget(info: $0) } },
                set: { revokeCandidate = $0?.info }
            )) { target in
                Alert(
                    title: Text("吊销邀请码 \(target.info.code)？"),
                    message: Text("吊销后该码不能再用于注册。已用次数不变。"),
                    primaryButton: .destructive(Text("吊销")) {
                        Task { await doRevoke(target.info) }
                    },
                    secondaryButton: .cancel()
                )
            }
            .task { await refresh() }
        }
    }

    @ViewBuilder
    private func inviteRow(_ inv: InviteInfo) -> some View {
        let status = statusText(inv)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(inv.code)
                    .font(.system(.title3, design: .monospaced).weight(.bold))
                    .foregroundColor(inv.disabled ? .secondary : .primary)
                Spacer()
                Text(status.label)
                    .font(.caption.weight(.medium))
                    .foregroundColor(status.color)
            }
            HStack(spacing: 14) {
                Label("\(inv.used_count)/\(inv.max_uses)", systemImage: "person.2")
                if let exp = inv.expires_at {
                    Label("至 \(exp.prefix(10))", systemImage: "calendar")
                } else {
                    Label("永不过期", systemImage: "infinity")
                }
            }
            .font(.caption)
            .foregroundColor(.secondary)
            if !inv.note.isEmpty {
                Text("备注：\(inv.note)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            HStack(spacing: 10) {
                Button {
                    UIPasteboard.general.string = inv.code
                    copiedTip = "已复制 \(inv.code)"
                } label: {
                    Label("复制", systemImage: "doc.on.doc")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.bordered)
                .tint(.orange)
                .disabled(inv.disabled)

                if !inv.disabled {
                    Button {
                        let text = "用我 CoursePet 的邀请码 \(inv.code) 注册吧～"
                        let av = UIActivityViewController(activityItems: [text], applicationActivities: nil)
                        UIApplication.shared.connectedScenes
                            .compactMap { $0 as? UIWindowScene }
                            .first?.keyWindow?.rootViewController?
                            .present(av, animated: true)
                    } label: {
                        Label("分享", systemImage: "square.and.arrow.up")
                            .font(.caption.weight(.medium))
                    }
                    .buttonStyle(.bordered)
                }

                Spacer()

                if !inv.disabled {
                    Button(role: .destructive) {
                        revokeCandidate = inv
                    } label: {
                        Image(systemName: "trash")
                            .font(.caption)
                    }
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial)
        )
        .overlay(alignment: .bottom) {
            if copiedTip != nil {
                Text(copiedTip ?? "")
                    .font(.caption2)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.thinMaterial, in: Capsule())
                    .padding(.bottom, -22)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 16)
    }

    private func statusText(_ inv: InviteInfo) -> (label: String, color: Color) {
        if inv.disabled { return ("已吊销", .secondary) }
        if inv.used_count >= inv.max_uses { return ("已用尽", .orange) }
        if let exp = inv.expires_at, exp < ISO8601DateFormatter().string(from: Date()) {
            return ("已过期", .secondary)
        }
        return ("可用", .green)
    }

    private func refresh() async {
        loading = true
        errorMessage = nil
        defer { loading = false }
        do {
            invites = try await InviteAPI.list(baseURL: baseURL)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func doRevoke(_ inv: InviteInfo) async {
        do {
            try await InviteAPI.revoke(baseURL: baseURL, id: inv.id)
            // 局部刷新：避免再发一次 list
            if let idx = invites.firstIndex(where: { $0.id == inv.id }) {
                let updated = InviteInfo(
                    id: inv.id, code: inv.code, note: inv.note,
                    max_uses: inv.max_uses, used_count: inv.used_count,
                    expires_at: inv.expires_at, disabled: true
                )
                invites[idx] = updated
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private struct RevokeTarget: Identifiable {
        let info: InviteInfo
        var id: Int { info.id }
    }
}

// MARK: - 生成邀请码弹窗

private struct CreateInviteSheet: View {

    let baseURL: String
    let onCreated: (InviteInfo) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var note: String = ""
    @State private var expiresDays: Int = 7       // 1/7/30/0（永久）
    @State private var maxUses: Int = 1            // 1/3/10
    @State private var loading = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("备注（给谁用）") {
                    TextField("例：张三", text: $note)
                }
                Section("有效期") {
                    Picker("", selection: $expiresDays) {
                        Text("1 天").tag(1)
                        Text("7 天").tag(7)
                        Text("30 天").tag(30)
                        Text("永久").tag(0)
                    }
                    .pickerStyle(.segmented)
                }
                Section("可用人数") {
                    Picker("", selection: $maxUses) {
                        Text("1 人").tag(1)
                        Text("3 人").tag(3)
                        Text("10 人").tag(10)
                    }
                    .pickerStyle(.segmented)
                }
                if let err = errorMessage {
                    Section { Text(err).foregroundColor(.red).font(.caption) }
                }
            }
            .navigationTitle("生成邀请码")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await create() }
                    } label: {
                        if loading { ProgressView() } else { Text("生成") }
                    }
                    .disabled(loading)
                }
            }
        }
    }

    private func create() async {
        loading = true
        errorMessage = nil
        defer { loading = false }
        do {
            let inv = try await InviteAPI.create(
                baseURL: baseURL, note: note,
                maxUses: maxUses, expiresDays: expiresDays
            )
            onCreated(inv)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
