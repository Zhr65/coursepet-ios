// MARK: - 学校教务登录 + 课表导入（端侧 WebView 直连）
// 链路：WebView 加载教务系统(jw.xjit.edu.cn) → 自动跳 CAS(cas.xjit.edu.cn) →
//       用户在 WebView 里输学号/密码/验证码登录 → CAS 回跳建立会话 →
//       用户导航到「课表页」→ 点「提取课表」执行 extractorJS → 原始表格映射成 Course →
//       复用 CourseImportConfirmView 预览（逐课改时间/地点）→ 导入 DataManager。
// CAS 带验证码，无法自动登录；凭据只存手机 Keychain（JiaoWuStore），登录动作仍在 WebView 内。
import SwiftUI
import WebKit
import UIKit

extension Notification.Name {
    /// JiaoWuLoginView 点「提取课表」→ 通知 WebView 容器执行 JS 抽取
    static let jiaowuExtract = Notification.Name("jiaowu.extract")
}

struct JiaoWuLoginView: View {
    let school: School
    @Environment(\.dismiss) private var dismiss

    @State private var extracting = false
    @State private var extracted: [Course] = []
    @State private var errorMessage: String?
    @State private var showPreview = false
    @State private var showAccountSheet = false
    @State private var sidInput = ""
    @State private var pwdInput = ""
    @AppStorage("school.boundId") private var boundSchoolId = 0

    var body: some View {
        NavigationStack {
            ZStack {
                JiaoWuWebView(
                    url: URL(string: school.loginBaseURL)!,
                    extractorJS: school.extractorJS,
                    onExtracted: { courses in
                        extracting = false
                        if courses.isEmpty {
                            errorMessage = "没从当前页抽到课表。请先在网页里点进「课表/我的课表」，再点「提取课表」。"
                        } else {
                            extracted = courses
                            showPreview = true
                        }
                    },
                    onError: { msg in
                        extracting = false
                        errorMessage = msg
                    }
                )
                .ignoresSafeArea()

                if extracting {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("正在提取课表…").font(.caption).foregroundColor(.secondary)
                    }
                    .padding(14)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                    .padding(.bottom, 40)
                }
            }
            .navigationTitle(school.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("提取课表") { triggerExtract() }
                        .disabled(extracting)
                }
            }
            .sheet(isPresented: $showPreview) {
                if !extracted.isEmpty {
                    CourseImportConfirmView(courses: extracted, originalImage: UIImage())
                }
            }
            .sheet(isPresented: $showAccountSheet) {
                accountSheet
            }
            .alert("提取失败", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } })
            ) {
                Button("好的") { errorMessage = nil }
                Button("记住学号") { showAccountSheet = true }
            } message: {
                Text(errorMessage ?? "")
            }
        }
        .onAppear { boundSchoolId = school.id }
    }

    private func triggerExtract() {
        extracting = true
        errorMessage = nil
        NotificationCenter.default.post(name: .jiaowuExtract, object: nil)
    }

    // 记忆学号（CAS 验证码无法自动登录，此凭据仅作「记住学号」+ 未来预留）
    private var accountSheet: some View {
        NavigationStack {
            Form {
                Section("教务账号（仅存本机）") {
                    TextField("学号", text: $sidInput)
                    SecureField("密码", text: $pwdInput)
                }
                Section {
                    Button("保存") {
                        JiaoWuStore.saveStudent(sidInput, pwdInput)
                        showAccountSheet = false
                    }
                    .disabled(sidInput.isEmpty)
                }
            }
            .navigationTitle("记住学号")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { showAccountSheet = false }
                }
            }
        }
        .onAppear {
            if let s = JiaoWuStore.loadStudent() {
                sidInput = s.sid; pwdInput = s.pwd
            }
        }
    }
}

// MARK: - WebView 容器

struct JiaoWuWebView: UIViewControllerRepresentable {
    let url: URL
    let extractorJS: String
    let onExtracted: ([Course]) -> Void
    let onError: (String) -> Void

    func makeCoordinator() -> JiaoWuCoordinator {
        JiaoWuCoordinator(extractorJS: extractorJS, onExtracted: onExtracted, onError: onError)
    }

    func makeUIViewController(context: Context) -> JiaoWuVC {
        let vc = JiaoWuVC()
        vc.startURL = url
        vc.coordinator = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: JiaoWuVC, context: Context) {}
}

final class JiaoWuVC: UIViewController, WKNavigationDelegate {
    var startURL: URL!
    var coordinator: JiaoWuCoordinator!
    private var webView: WKWebView!

    override func viewDidLoad() {
        super.viewDidLoad()
        let cfg = WKWebViewConfiguration()
        // 允许 CAS 回跳的 cookie / 会话驻留（默认 WKWebsiteDataStore 即足够）
        webView = WKWebView(frame: view.bounds, configuration: cfg)
        webView.navigationDelegate = self
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView.allowsBackForwardNavigationGestures = true
        view.addSubview(webView)
        webView.load(URLRequest(url: startURL))
        NotificationCenter.default.addObserver(
            self, selector: #selector(doExtract), name: .jiaowuExtract, object: nil)
    }

    @objc private func doExtract() {
        coordinator.extract(from: webView)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // 调试：登录跳转过程中若失败可在此观察
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        NSLog("[JiaoWu] 导航失败: %@", error.localizedDescription)
    }
}

final class JiaoWuCoordinator {
    private let extractorJS: String
    private let onExtracted: ([Course]) -> Void
    private let onError: (String) -> Void

    init(extractorJS: String, onExtracted: @escaping ([Course]) -> Void, onError: @escaping (String) -> Void) {
        self.extractorJS = extractorJS
        self.onExtracted = onExtracted
        self.onError = onError
    }

    func extract(from webView: WKWebView) {
        let js = extractorJS
        webView.evaluateJavaScript(js) { [weak self] result, error in
            guard let self else { return }
            if let error {
                DispatchQueue.main.async {
                    self.onError("课表抽取失败：\(error.localizedDescription)")
                }
                return
            }
            guard let str = result as? String,
                  let data = str.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rows = obj["rows"] as? [[String]] else {
                DispatchQueue.main.async {
                    self.onError("课表页结构未识别（请确认已打开课表页）。")
                }
                return
            }
            // 用当前目录首校做映射（MVP 仅新疆理工；后续按 webView 实际学校传 school）
            guard let school = SchoolCatalog.schools.first else {
                DispatchQueue.main.async { self.onError("学校目录为空") }
                return
            }
            let courses = SchoolCatalog.mapRows(rows, school: school)
            DispatchQueue.main.async {
                self.onExtracted(courses)
            }
        }
    }
}
