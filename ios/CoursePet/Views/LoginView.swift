// MARK: - 登录页（用户名密码 + 邀请码注册）
// App 启动时：AuthStore.isLoggedIn == false → 显示本页
// 登录成功 → 存 AuthTokens 进 Keychain → 自动进入主页
//
// 设计取舍：Sign in with Apple 按钮已移除。
//   原因：SideStore 用个人免费 Apple ID 重签包拿不到 applesignin entitlement
//   （Apple 付费 Developer 限制），点了会红字报错「重签丢权限」。
//   留着按钮 = 误导每个新用户，删了 = 引导用账号密码。
//
// 服务器地址展示已改：不再显示完整 URL（避免把开发者服务器 IP 泄露给所有安装者），
//   改成 "已配置 ✅ / 未配置 ⚠️" + 跳设置页。
import SwiftUI

struct LoginView: View {

    @StateObject private var server = ServerConfigState()    // 从 AgentConfigStore 读当前服务器地址

    @State private var username = ""
    @State private var password = ""
    @State private var inviteCode = ""                       // 注册时填的邀请码
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var isRegister = false                    // false=登录 / true=注册

    /// 登录成功后通知外层（ContentView）切换到主页
    var onLoggedIn: () -> Void
    /// 点击"游客模式"：进入端侧模式，不拦登录墙（下次启动还会回到登录页直到真正登录）
    var onSkipped: () -> Void

    var body: some View {
        ZStack {
            // 渐变背景（和养成页同色系）
            LinearGradient(colors: [.yellow.opacity(0.15), .orange.opacity(0.15), .pink.opacity(0.15)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()

            VStack(spacing: 28) {
                // 🐾 品牌区
                VStack(spacing: 12) {
                    Image(systemName: "pawprint.circle.fill")
                        .resizable().frame(width: 64, height: 64)
                        .foregroundStyle(.orange)
                    Text("CoursePet")
                        .font(.largeTitle.bold())
                    Text("口袋宠物管家")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 40)

                // 📝 用户名密码登录
                VStack(spacing: 12) {
                    TextField("用户名", text: $username)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("密码", text: $password)
                        .textFieldStyle(.roundedBorder)

                    if isRegister {
                        VStack(alignment: .leading, spacing: 4) {
                            TextField("邀请码", text: $inviteCode)
                                .textFieldStyle(.roundedBorder)
                                .textInputAutocapitalization(.characters)
                                .autocorrectionDisabled()
                            Text("注册需要邀请码，可向管理员索取")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Button {
                        Task { await passwordSubmit() }
                    } label: {
                        Text(isRegister ? "注册" : "登录")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color.orange, in: RoundedRectangle(cornerRadius: 10))
                            .foregroundStyle(.white)
                    }
                    .disabled(isLoading || username.isEmpty || password.isEmpty
                              || (isRegister && inviteCode.isEmpty))

                    Button(isRegister ? "已有账号？登录" : "还没账号？注册") {
                        withAnimation { isRegister.toggle() }
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }

                if let err = errorMessage {
                    Text(err).font(.footnote).foregroundStyle(.red)
                }

                Spacer()

                // 游客模式：不登录直接进（端侧模式照常用，服务器功能等登录后再说）
                Button {
                    onSkipped()
                } label: {
                    Text("游客模式（数据不上传）")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 8)

                // 服务器地址状态：不再显示完整 URL，避免泄露开发者服务器地址
                // 点进去可改（跳设置页）
                Button {
                    NotificationCenter.default.post(name: .coursepetOpenSettings, object: nil)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: server.baseURL.isEmpty ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .font(.caption2)
                        Text(server.baseURL.isEmpty ? "未配置服务器地址，点此设置" : "已配置服务器")
                            .font(.caption2)
                    }
                    .foregroundStyle(server.baseURL.isEmpty ? .orange : .secondary)
                }
                .padding(.bottom, 20)
            }
            .padding(.horizontal, 28)

            if isLoading {
                ProgressView()
                    .scaleEffect(1.5)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.black.opacity(0.15))
            }
        }
    }

    // MARK: - Actions

    private func passwordSubmit() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let tokens: AuthTokens
            if isRegister {
                tokens = try await AuthAPI.register(
                    baseURL: server.baseURL,
                    username: username, password: password,
                    invite: inviteCode,
                    petName: "小狼"
                )
            } else {
                tokens = try await AuthAPI.passwordLogin(
                    baseURL: server.baseURL,
                    username: username, password: password
                )
            }
            AuthStore.save(tokens)
            onLoggedIn()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - 服务器配置桥接（从 AgentConfigStore 读 baseURL）
private final class ServerConfigState: ObservableObject {
    @Published var baseURL: String = ""

    init() {
        let cfg = AgentConfigStore.loadServerConfig()
        baseURL = cfg.baseURL
    }
}
