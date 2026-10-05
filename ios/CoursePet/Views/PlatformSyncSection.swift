// MARK: - 课程平台同步（事务页作业列表内嵌段）
// 从设置页迁来：绑定入口放在作业页面里——点「学习通」账密登录、点「智慧树」扫码，
// 连接成功即拉取作业进列表。学习通/智慧树都由手机端直连（风控/WAF 拦服务器出口 IP），
// 凭据/会话只存手机 Keychain 不上传服务器；只同步自今天开始的作业，历史作业不导入。
// 依赖服务器模式入库（设置页填三项后可用）；回前台自动同步（3 分钟节流）。
import SwiftUI

struct PlatformSyncSection: View {
    @State private var platformAccounts: [AgentRemoteClient.PlatformAccountStatus] = []
    @State private var cxUser = ""
    @State private var cxPass = ""
    @State private var platformTip: String?
    @State private var platformBusy = false
    @State private var showUnbindConfirm = false
    @State private var showZhsUnbindConfirm = false
    @State private var showZhsQrSheet = false

    var body: some View {
        Section(header: Text("课程平台 · 自动同步作业"),
                footer: Text("绑定后手机直连平台拉取作业，只显示今天起截止的作业，历史作业不导入。学习通填账密登录，智慧树用智慧树 App 扫码（约 5 分钟有效）。凭据只存手机，回前台自动同步，平台显示「已提交」的作业自动标记完成。")) {
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
                TextField("学习通账号（手机号 / 学号）", text: $cxUser)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                SecureField("学习通密码", text: $cxPass)
                Button {
                    bindChaoxing()
                } label: {
                    Label("登录学习通并同步作业", systemImage: "link")
                        .frame(maxWidth: .infinity)
                }
                .disabled(platformBusy || cxUser.trimmingCharacters(in: .whitespaces).isEmpty || cxPass.isEmpty)
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

    // MARK: 学习通绑定（端侧直连验证 + 拉作业 + 凭据只存手机 + 上报服务器）
    private func bindChaoxing() {
        let user = cxUser.trimmingCharacters(in: .whitespacesAndNewlines)
        let pass = cxPass
        guard !user.isEmpty, !pass.isEmpty else { return }
        let server = AgentConfigStore.loadServerConfig()
        guard server.isConfigured else {
            platformTip = "绑定失败：请先在设置页配置服务器模式"
            return
        }
        platformBusy = true
        platformTip = "正在直连学习通验证并拉取作业…"
        Task { @MainActor in
            defer { platformBusy = false }
            let outcome = await ChaoxingClient.sync(username: user, password: pass)
            guard outcome.error.isEmpty else {
                platformTip = "绑定失败：\(outcome.error)"
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                return
            }
            ChaoxingClient.Credentials.save(user: user, pass: pass)
            AgentRemoteClient.mergeAssignments(outcome.items, onlyPrune: ["chaoxing"])
            let pushOk = await AgentRemoteClient.pushAssignments(
                baseURL: server.baseURL, username: server.username, password: server.password,
                platform: "chaoxing", platformUser: user,
                items: outcome.items, complete: outcome.complete, error: "")
            await reloadPlatformStatus(server: server)
            platformTip = pushOk ? "绑定成功，今天的作业已进列表"
                                 : "绑定成功，但上报服务器失败（回前台会自动重试）"
            cxPass = ""
            UINotificationFeedbackGenerator().notificationOccurred(.success)
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
