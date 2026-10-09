// MARK: - Sign in with Apple 封装
// 用法：
//   let result = await AppleAuth.signIn()
//   switch result {
//   case .success(let credential):
//       // credential.identityToken → 发给后端 POST /auth/apple-login
//   case .failure(let error):
//       // 用户取消或 Apple 验证失败
//   }
import AuthenticationServices
import Foundation

enum AppleAuthError: LocalizedError {
    case notSupported           // 模拟器 / iOS 版本太低
    case noIdentityToken        // Apple 没给 token（极少见）
    case cancelled              // 用户点了取消
    case other(Error)

    var errorDescription: String? {
        switch self {
        case .notSupported:   return "当前设备不支持 Apple 登录"
        case .noIdentityToken: return "Apple 登录未返回身份凭证"
        case .cancelled:      return "已取消"
        case .other(let e):   return e.localizedDescription
        }
    }
}

/// Apple 登录成功的凭证（直接发给后端即可）
struct AppleCredential {
    let identityToken: String         // 后端最关键——用这个去苹果公钥验证
    let givenName: String?            // 只在用户第一次授权时有值
    let familyName: String?
    let fullName: String?             // 拼接好的全名，方便直接当 pet_name 初始值
}

@MainActor
enum AppleAuth {

    /// 拉起 Apple 登录弹窗。用户 Face ID / Touch ID 验证后返回凭证。
    /// 用 ASAuthorizationAppleIDProvider（非 Password AutoFill，因为我们要自定义昵称/邮箱请求）。
    static func signIn() async -> Result<AppleCredential, AppleAuthError> {
        guard #available(iOS 13, *) else { return .failure(.notSupported) }

        let provider = ASAuthorizationAppleIDProvider()
        let request = provider.createRequest()
        request.requestedScopes = [.fullName, .email]   // 第一次授权时拿全名和邮箱

        do {
            let authorization = try await performRequest(request)
            guard let appleIDCredential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let identityTokenData = appleIDCredential.identityToken,
                  let identityToken = String(data: identityTokenData, encoding: .utf8) else {
                return .failure(.noIdentityToken)
            }
            let given = appleIDCredential.fullName?.givenName
            let family = appleIDCredential.fullName?.familyName
            return .success(AppleCredential(
                identityToken: identityToken,
                givenName: given,
                familyName: family,
                fullName: [given, family].compactMap { $0 }.joined(separator: " ")
            ))
        } catch let err as ASAuthorizationError {
            if err.code == .canceled { return .failure(.cancelled) }
            return .failure(.other(err))
        } catch {
            return .failure(.other(error))
        }
    }

    /// ASAuthorizationController 需要 delegate。Delegate 自身持有 controller，
    /// controller 强持有 delegate（通过 delegate 的 controller 属性），形成循环引用防止释放。
    private static func performRequest(_ request: ASAuthorizationRequest) async throws -> ASAuthorization {
        try await withCheckedThrowingContinuation { continuation in
            let controller = ASAuthorizationController(authorizationRequests: [request])
            let delegate = Delegate(continuation: continuation)
            delegate.controller = controller    // 循环引用保活 delegate
            controller.delegate = delegate
            controller.presentationContextProvider = delegate
            controller.performRequests()
        }
    }

    /// 一次性 delegate：成功 resume continuation，失败或取消也 resume（不过带 error）。
    private final class Delegate: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
        private let continuation: CheckedContinuation<ASAuthorization, Error>
        weak var controller: ASAuthorizationController?
        private var resumed = false

        init(continuation: CheckedContinuation<ASAuthorization, Error>) {
            self.continuation = continuation
        }

        func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
            guard !resumed else { return }
            resumed = true
            continuation.resume(returning: authorization)
        }

        func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
            guard !resumed else { return }
            resumed = true
            continuation.resume(throwing: error)
        }

        func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
            if #available(iOS 13, *) {
                for scene in UIApplication.shared.connectedScenes {
                    if let ws = scene as? UIWindowScene {
                        for w in ws.windows where w.isKeyWindow { return w }
                    }
                }
            }
            return UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap { $0.windows }
                .first(where: \.isKeyWindow) ?? UIWindow()
        }
    }
}
