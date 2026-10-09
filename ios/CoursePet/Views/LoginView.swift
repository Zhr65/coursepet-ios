// MARK: - 登录页（Sign in with Apple + 用户名密码 二选一）
// App 启动时：AuthStore.isLoggedIn == false → 显示本页
// 登录成功 → 存 AuthTokens 进 Keychain → 自动进入主页
import SwiftUI

struct LoginView: View {

    @StateObject private var server = ServerConfigState()    // 从 AgentConfigStore 读当前服务器地址

    @State private var username = ""
    @State private var password = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var isRegister = false                    // false=登录 / true=注册

    /// 登录成功后通知外层（ContentView）切换到主页
    var onLoggedIn: () -> Void
    /// 点击"先跳过"：进入端侧模式，不拦登录墙（下次启动还会回到登录页直到真正登录）
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

                // 🔴 Sign in with Apple
                Button {
                    Task { await appleSignIn() }
                } label: {
                    HStack {
                        Image(systemName: "apple.logo")
                        Text("通过 Apple 登录")
                            .font(.headline)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.black, in: RoundedRectangle(cornerRadius: 12))
                    .foregroundStyle(.white)
                }
                .disabled(isLoading || server.baseURL.isEmpty)

                HStack {
                    Rectangle().fill(.quaternary).frame(height: 1)
                    Text("或").font(.footnote).foregroundStyle(.secondary)
                    Rectangle().fill(.quaternary).frame(height: 1)
                }

                // 📝 用户名密码登录
                VStack(spacing: 12) {
                    TextField("用户名", text: $username)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("密码", text: $password)
                        .textFieldStyle(.roundedBorder)

                    if isRegister {
                        SecureField("再次输入密码", text: .constant(""))
                            .textFieldStyle(.roundedBorder)
                            .disabled(true)
                            .overlay(Text("（后续开放）").foregroundStyle(.secondary).font(.caption))
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
                    .disabled(isLoading || username.isEmpty || password.isEmpty)

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

                // 先跳过：不登录直接进（端侧模式照常用，服务器功能等登录后再说）
                Button {
                    onSkipped()
                } label: {
                    Text("先跳过，直接使用")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 20)

                // 服务器地址提示（调试用，生产可隐藏）
                if server.baseURL.isEmpty {
                    Text("⚠️ 未配置服务器地址")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else {
                    Text("服务器：\(server.baseURL)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
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

    private func appleSignIn() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        // 1. Apple 弹窗
        let result = await AppleAuth.signIn()
        let credential: AppleCredential
        switch result {
        case .success(let c): credential = c
        case .failure(.cancelled): return
        case .failure(let err):
            errorMessage = err.localizedDescription
            return
        }

        // 2. 发后端
        do {
            let tokens = try await AuthAPI.appleLogin(baseURL: server.baseURL, credential: credential)
            AuthStore.save(tokens)
            onLoggedIn()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func passwordSubmit() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let tokens: AuthTokens
            if isRegister {
                tokens = try await AuthAPI.register(
                    baseURL: server.baseURL,
                    username: username, password: password
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
