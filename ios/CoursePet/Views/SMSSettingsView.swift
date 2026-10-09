// MARK: - 短信助手设置页（设置 → 自动化 → 短信助手）
// 一个开关管两条通道：
//   A. 私有 API 监听（灰色，侧载自用）：App 活着就自动收，零配置
//   B. 快捷指令自动化（正规兜底）：系统「收到信息」触发器 → 「处理短信」，App 被杀也能跑
// 双通道同时命中由 60 秒去重兜住；短信原文全程不出手机。
import SwiftUI
import UserNotifications

struct SMSSettingsView: View {
    @AppStorage("sms.enabled") private var enabled = false
    @State private var statusText = ""
    @State private var testTip: String?
    @State private var testBusy = false

    var body: some View {
        Form {
            // ── 总开关 + 双通道状态 ──
            Section(footer: Text("开一次即可，两条通道同时生效：App 进程活着时灰色通道直接听（零配置）；App 被杀后靠快捷指令自动化兜底（配一次永久有效）。同一条短信两条路都到时自动去重，只处理一次。短信原文全程不出手机。")) {
                Toggle(isOn: $enabled) {
                    HStack(spacing: 10) {
                        Image(systemName: "message.badge.fill")
                            .foregroundColor(.green)
                        Text("短信自动处理")
                    }
                }
                .onChange(of: enabled) { on in
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    SMSSyncManager.setEnabled(on)
                    if on {
                        // 快递确认/验证码提醒都走本地通知，开启时顺手要权限
                        NotificationManager.requestAuthorization()
                    }
                    refreshStatus()
                }
                Text(statusText)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // ── 会自动处理什么（分类一览）──
            Section(header: Text("会自动处理什么")) {
                categoryRow(icon: "shippingbox", color: .orange,
                            title: "快递短信", desc: "自动记取件码和驿站，今晚 20:00 提醒取件")
                categoryRow(icon: "keyboard", color: .blue,
                            title: "验证码", desc: "自动复制到剪贴板，弹通知告诉你")
                categoryRow(icon: "creditcard", color: .red,
                            title: "银行/支付", desc: "金额变动弹提醒（本地通知 + Bark 镜像）")
                categoryRow(icon: "graduationcap", color: .green,
                            title: "学校/教务", desc: "停课调课等通知记进宠物记忆，聊天时能想起来")
                categoryRow(icon: "moon.zzz.fill", color: .gray,
                            title: "其他短信", desc: "静默忽略，不打扰")
            }

            // ── 快捷指令自动化配置引导（路径 B）──
            Section(header: Text("快捷指令自动化 · 推荐配置"),
                    footer: Text("灰色通道需要 App 进程活着；配一条自动化后，App 被杀也能收到处理结果。系统大版本更新导致灰色通道失效时，这条路永远在。")) {
                VStack(alignment: .leading, spacing: 8) {
                    guideRow("① 打开系统「快捷指令」App → 底部「自动化」→ 右上角 + → 选「收到信息」")
                    guideRow("② 发件人留空（收任何人的短信都触发），打开「立即运行，无需询问」，点下一步")
                    guideRow("③ 选「新建空白自动化」→ 添加操作 → 搜「CoursePet」→ 选「处理短信」")
                    guideRow("④ 点操作里的「发件人」参数 → 选变量「发件人」；点「内容」参数 → 选变量「信息内容」")
                    guideRow("⑤ 完成。来条真实短信试试，或用下面的测试按钮")
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }

            // ── 测试（真实走一遍路由，会真写数据）──
            Section(header: Text("测试"), footer: Text("测试会真实执行动作：快递会写入事务页快递列表（可删）、验证码会覆盖剪贴板，用来验证整条链路。")) {
                HStack(spacing: 12) {
                    Button {
                        runTest(Self.parcelSample)
                    } label: {
                        Label("快递短信", systemImage: "shippingbox.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    Button {
                        runTest(Self.otpSample)
                    } label: {
                        Label("验证码", systemImage: "keyboard")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                if let tip = testTip {
                    Text(tip)
                        .font(.caption)
                        .foregroundColor(tip.hasPrefix("已关闭") ? .orange : .secondary)
                }
            }
        }
        .navigationTitle("短信助手")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { refreshStatus() }
    }

    // MARK: - 测试样本（贴近真实格式）
    private static let parcelSample =
        "【菜鸟驿站】您有一个包裹已到站：菜鸟驿站(东区店)，取件码 10-2-3041，请及时领取，拒收请回复R。"
    private static let otpSample =
        "【工商银行】您的验证码是 824613，5 分钟内有效，请勿泄露给他人。"

    // MARK: - 子视图
    private func categoryRow(icon: String, color: Color, title: String, desc: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(color)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(desc)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func guideRow(_ text: String) -> some View {
        Text(text)
    }

    // MARK: - 状态回显
    private func refreshStatus() {
        switch SMSSyncManager.status {
        case .installed:
            statusText = "灰色通道：已装上私有 API 监听（收不到短信就按上面配一条快捷指令）"
        case .unavailable:
            statusText = "灰色通道：本机不可用（私有符号探测失败），走快捷指令方案即可"
        case .off:
            statusText = "当前关闭。打开后灰色通道立即可用，无需任何配置"
        }
    }

    // MARK: - 测试执行
    private func runTest(_ text: String) {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        guard !testBusy else { return }
        testBusy = true
        testTip = "正在处理…"
        // handle 是同步的，包一层 Task 让按钮先刷新；bark 镜像内部自己异步
        Task { @MainActor in
            let summary = SMSEventRouter.handle(sender: "1069000000", text: text)
            testTip = summary
            testBusy = false
        }
    }
}
