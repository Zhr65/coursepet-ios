// MARK: - 课程平台同步（事务页作业列表内嵌段）
// 从设置页迁来：绑定入口放在作业页面里——点「学习通」账密登录、点「智慧树」扫码，
// 连接成功即拉取作业进列表。学习通/智慧树都由手机端直连（风控/WAF 拦服务器出口 IP），
// 凭据/会话只存手机 Keychain 不上传服务器；只同步自今天开始的作业，历史作业不导入。
// 依赖服务器模式入库（设置页填三项后可用）；回前台自动同步（3 分钟节流）。
import SwiftUI

struct PlatformSyncSection: View {
    @State private var platformAccounts: [AgentRemoteClient.PlatformAccountStatus] = []
    @State private var platformTip: String?
    @State private var platformBusy = false
    @State private var showUnbindConfirm = false
    @State private var showZhsUnbindConfirm = false
    @State private var showZhsQrSheet = false
    @State private var showCxQrSheet = false
    @State private var platformExpanded = false

    private var boundCount: Int { platformAccounts.count }

    var body: some View {
        Section {
            // 默认收起：作业页只留一行低调入口，点开才显示绑定/解绑/刷新
            DisclosureGroup(isExpanded: $platformExpanded) {
                // 学习通
                if let cx = platformAccounts.first(where: { $0.platform == "chaoxing" }) {
                    boundRow(platform: "学习通", account: cx)
                    Button(role: .destructive) {
                        showUnbindConfirm = true
                    } label: {
                        Label("解绑学习通", systemImage: "minus.circle")
                    }
                    .disabled(platformBusy)
                    .alert("解绑学习通？", isPresented: $showUnbindConfirm) {
                        Button("解绑", role: .destructive) { unbindChaoxing() }
                        Button("取消", role: .cancel) { }
                    } message: {
                        Text("同步来的学习通作业会一并删除，手动添加的作业不受影响。")
                    }
                } else {
                    Button {
                        showCxQrSheet = true
                    } label: {
                        Label("扫码绑定学习通", systemImage: "qrcode")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(platformBusy)
                }
                // 智慧树
                if let zhs = platformAccounts.first(where: { $0.platform == "zhihuishu" }) {
                    boundRow(platform: "智慧树", account: zhs)
                    Button(role: .destructive) {
                        showZhsUnbindConfirm = true
                    } label: {
                        Label("解绑智慧树", systemImage: "minus.circle")
                    }
                    .disabled(platformBusy)
                    .alert("解绑智慧树？", isPresented: $showZhsUnbindConfirm) {
                        Button("解绑", role: .destructive) { unbindZhihuishu() }
                        Button("取消", role: .cancel) { }
                    } message: {
                        Text("同步来的智慧树作业会一并删除，手动添加的作业不受影响。")
                    }
                } else {
                    Button {
                        showZhsQrSheet = true
                    } label: {
                        Label("扫码绑定智慧树", systemImage: "qrcode")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(platformBusy)
                }
                if let tip = platformTip {
                    Text(tip)
                        .font(.caption)
                        .foregroundColor(tip.hasPrefix("绑定失败") || tip.hasPrefix("解绑失败") || tip.hasPrefix("刷新失败") ? .red : .secondary)
                }
                Button {
                    refreshAssignmentsNow()
                } label: {
                    Label("立即刷新作业", systemImage: "arrow.clockwise")
                }
                .disabled(platformBusy || platformAccounts.isEmpty)
            } label: {
                HStack {
                    Label("课程平台绑定", systemImage: "qrcode")
                    Spacer()
                    if boundCount > 0 {
                        Text("已绑定 \(boundCount) 个").font(.caption).foregroundColor(.secondary)
                    }
                }
            }
        }
        .onAppear {
            let server = AgentConfigStore.loadServerConfig()
            if server.isConfigured {
                Task { @MainActor in await reloadPlatformStatus(server: server) }
            }
        }
        .sheet(isPresented: $showZhsQrSheet) {
            ZhihuishuQRSheet {
                // confirmed 回调：首拉已完成，强刷本地 + 刷新绑定状态行
                platformTip = "绑定成功，新作业会自动出现在列表"
                Task { @MainActor in
                    await AgentRemoteClient.syncAssignmentsIfNeeded(force: true)
                    await reloadPlatformStatus(server: AgentConfigStore.loadServerConfig())
                }
            }
        }
        .sheet(isPresented: $showCxQrSheet) {
            ChaoxingQRSheet { outcome in
                handleCxConfirmed(outcome)
            }
        }
    }

    // MARK: 学习通扫码确认后：合并 + 上报 + 刷状态
    private func handleCxConfirmed(_ outcome: ChaoxingClient.SyncOutcome) {
        platformTip = "绑定成功，今天的作业已进列表"
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        let server = AgentConfigStore.loadServerConfig()
        AgentRemoteClient.mergeAssignments(outcome.items, onlyPrune: ["chaoxing"])
        guard server.isConfigured else {
            platformTip = "扫码成功、作业已进手机，但需在设置页配置服务器模式才能入库"
            return
        }
        Task { @MainActor in
            let pushOk = await AgentRemoteClient.pushAssignments(
                baseURL: server.baseURL, username: server.username, password: server.password,
                platform: "chaoxing", platformUser: outcome.username.isEmpty ? "学习通用户" : outcome.username,
                items: outcome.items, complete: outcome.complete, error: "")
            await reloadPlatformStatus(server: server)
            if !pushOk {
                platformTip = "已同步到手机，但上报服务器失败（回前台会自动重试）"
            }
        }
    }

    // MARK: 已绑定状态行
    private func boundRow(platform: String, account: AgentRemoteClient.PlatformAccountStatus) -> some View {
        HStack(spacing: 10) {
            Image(systemName: account.status == "ok" ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .foregroundColor(account.status == "ok" ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(platform) · \(account.username)")
                Text(statusText(account))
                    .font(.caption)
                    .foregroundColor(account.status == "ok" ? .secondary : .orange)
            }
            Spacer()
        }
    }

    private func statusText(_ a: AgentRemoteClient.PlatformAccountStatus) -> String {
        switch a.status {
        case "ok": return "同步正常"
        case "auth_failed": return a.lastError.isEmpty ? "登录失效，请解绑后重新绑定" : a.lastError
        default: return a.lastError.isEmpty ? "同步异常" : a.lastError
        }
    }

    private func reloadPlatformStatus(server: AgentConfigStore.ServerConfig) async {
        if let result = try? await AgentRemoteClient.fetchPlatformSync(
            baseURL: server.baseURL, username: server.username, password: server.password) {
            platformAccounts = result.accounts
        }
    }

    private func unbindChaoxing() {
        let server = AgentConfigStore.loadServerConfig()
        guard server.isConfigured else { return }
        platformBusy = true
        Task { @MainActor in
            defer { platformBusy = false }
            let ok = await AgentRemoteClient.unbindPlatformAccount(
                baseURL: server.baseURL, username: server.username,
                password: server.password, platform: "chaoxing")
            if ok {
                ChaoxingClient.Credentials.clear()
                await AgentRemoteClient.syncAssignmentsIfNeeded(force: true)
                await reloadPlatformStatus(server: server)
                platformTip = "已解绑，同步来的作业已清除"
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } else {
                platformTip = "解绑失败：服务器暂时连不上"
            }
        }
    }

    private func unbindZhihuishu() {
        let server = AgentConfigStore.loadServerConfig()
        guard server.isConfigured else { return }
        platformBusy = true
        Task { @MainActor in
            defer { platformBusy = false }
            let ok = await AgentRemoteClient.unbindPlatformAccount(
                baseURL: server.baseURL, username: server.username,
                password: server.password, platform: "zhihuishu")
            if ok {
                AgentZhsClient.Credentials.clear()
                await AgentRemoteClient.syncAssignmentsIfNeeded(force: true)
                await reloadPlatformStatus(server: server)
                platformTip = "已解绑，同步来的作业已清除"
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } else {
                platformTip = "解绑失败：服务器暂时连不上"
            }
        }
    }

    private func refreshAssignmentsNow() {
        let server = AgentConfigStore.loadServerConfig()
        guard server.isConfigured else { return }
        platformBusy = true
        platformTip = "正在刷新平台作业…"
        Task { @MainActor in
            defer { platformBusy = false }
            let ok = await AgentRemoteClient.refreshPlatformAssignments(
                baseURL: server.baseURL, username: server.username, password: server.password)
            await AgentRemoteClient.syncAssignmentsIfNeeded(force: true)
            await reloadPlatformStatus(server: server)
            platformTip = ok ? "已刷新，作业列表已更新" : "刷新失败：服务器暂时连不上"
        }
    }
}

// MARK: - 学习通扫码绑定（手机直连出码 + 轮询，二维码图官方 createqr 直出）
struct ChaoxingQRSheet: View {
    var onConfirmed: (ChaoxingClient.SyncOutcome) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var phase: Phase = .loading
    @State private var attempt = 0
    @State private var qrImage: UIImage?
    @State private var tip: String?

    enum Phase: Equatable { case loading, showing, scanned, syncing, expired, failed }

    var body: some View {
        VStack(spacing: 14) {
            Capsule().fill(Color.secondary.opacity(0.4)).frame(width: 36, height: 5).padding(.top, 10)
            Text("学习通扫码绑定").font(.headline)
            Text("用学习通 App 扫一扫，在手机上点确认登录").font(.subheadline).foregroundColor(.secondary)
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .strokeBorder(
                                LinearGradient(colors: [.white.opacity(0.65), .white.opacity(0.12)],
                                               startPoint: .topLeading, endPoint: .bottomTrailing),
                                lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.12), radius: 14, x: 0, y: 6)
                    .frame(width: 248, height: 248)
                if let img = qrImage, phase == .showing || phase == .scanned {
                    Image(uiImage: img).resizable().interpolation(.none)
                        .scaledToFit().frame(width: 216, height: 216).clipShape(RoundedRectangle(cornerRadius: 4))
                    if phase == .scanned {
                        RoundedRectangle(cornerRadius: 4).fill(.thinMaterial).frame(width: 216, height: 216)
                        VStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill").font(.system(size: 40)).foregroundColor(.green)
                            Text("已扫码，请在手机上确认").font(.footnote)
                        }
                    }
                } else if phase == .loading {
                    ProgressView("正在获取二维码…")
                } else if phase == .syncing {
                    ProgressView("登录成功，正在拉取作业…")
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle").font(.system(size: 36)).foregroundColor(.orange)
                        Text(tip ?? "二维码已失效").font(.footnote).multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                        Button("重新获取") { attempt += 1 }
                            .buttonStyle(.borderedProminent).controlSize(.small)
                    }
                }
            }
            if phase == .failed, let tip = tip {
                Text(tip).font(.caption).foregroundColor(.red).multilineTextAlignment(.center)
            }
            Spacer()
            Button("取消") { dismiss() }.foregroundStyle(.secondary).padding(.bottom, 16)
        }
        .presentationDetents([.large])
        .task(id: attempt) { await runFlow() }
    }

    private func runFlow() async {
        phase = .loading; tip = nil; qrImage = nil
        do {
            let session = try await ChaoxingClient.qrCreate()
            let (imgData, _) = try await URLSession.shared.data(from: ChaoxingClient.qrImageURL(session))
            qrImage = UIImage(data: imgData)
            phase = (qrImage == nil) ? .failed : .showing
            if qrImage == nil { tip = "二维码下载失败，请重新获取"; return }
            let deadline = Date().addingTimeInterval(150)
            while Date() < deadline {
                try await Task.sleep(nanoseconds: 2_000_000_000)
                let st = try await ChaoxingClient.qrPoll(session)
                switch st {
                case .waiting: continue
                case .scanned: phase = .scanned
                case .confirmed:
                    phase = .syncing
                    let outcome = await ChaoxingClient.syncAfterQR()
                    if outcome.error.isEmpty {
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                        onConfirmed(outcome)
                        dismiss()
                    } else {
                        phase = .failed; tip = outcome.error
                    }
                    return
                case .expired(let msg):
                    phase = .expired; tip = msg; return
                case .failed(let msg):
                    phase = .failed; tip = msg; return
                }
            }
            phase = .expired; tip = "二维码已过期，请重新获取"
        } catch {
            phase = .failed
            tip = error.localizedDescription
        }
    }
}
