// MARK: - 学校教务登录 + 课表导入（端侧 WebView 直连）
// 链路：WebView 加载教务系统(jw.xjit.edu.cn) → 未登录自动跳 CAS(cas.xjit.edu.cn) →
//       已记住凭据时自动填学号/密码（验证码仍需手动输，CAS 无法绕过）→
//       用户登录 → CAS 回跳建立会话 → didFinish 发现落在教务域 → 自动跳课表页(xskb_list.do)
//       → 自动抽课表（最多重试 2 次：金智部分渲染是异步的，0.6s 时课程格子可能还没出来）→
//       抽取结果走 CourseImportConfirmView 预览 → 导入 DataManager。
// 单双周两段式提取（2026-10-17）：学校课表格子把单双周课混在一起，周次文本无单双周信息。
//   用户在网页里把周次切到某单周（如第3周）→ 提取（全部课标 single，暂存）→
//   切到双周（如第4周）→ 再提取 → 自动合并成完整课表进预览。只提一次也能直接导入。
//   页面没切周次（全周视图）时 parity 按周次文本推断（全奇/全偶仍能判出）。
// 诊断：抽取 JS 总是返回页面结构诊断（表格数/表头/节次行/周次/CAS），失败弹窗展示 +
//   「复制诊断」按钮，真机问题可凭诊断数字远程定位，不用再盲猜。
// 凭据只存手机 Keychain（JiaoWuStore），不传服务器。
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
    /// 最近一次失败的诊断串（「复制诊断」按钮往剪贴板放的就是它）
    @State private var errorDiagText: String?
    @State private var showPreview = false
    @State private var showAccountSheet = false
    @State private var sidInput = ""
    @State private var pwdInput = ""
    /// 单双周两段式：第一次（周次下拉在奇/偶数周）提取的暂存
    @State private var pendingCourses: [Course] = []
    @State private var pendingContextWeek: Int?
    @State private var pendingMessage: String = ""
    @State private var showPendingAlert = false
    @AppStorage("school.boundId") private var boundSchoolId = 0

    var body: some View {
        NavigationStack {
            ZStack {
                JiaoWuWebView(
                    school: school,
                    onExtracted: { courses, diag in
                        handleExtracted(courses, diag: diag)
                    },
                    onError: { msg in
                        extracting = false
                        errorDiagText = nil
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
                // 记住学号常驻入口（以前埋在失败弹窗里，用户根本找不到）
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        showAccountSheet = true
                    } label: {
                        Image(systemName: "person.crop.circle")
                    }
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
                Button("复制诊断") {
                    UIPasteboard.general.string = errorDiagText ?? errorMessage
                    errorMessage = nil
                }
                Button("记住学号") { showAccountSheet = true }
            } message: {
                Text(errorMessage ?? "")
            }
            .alert("提取结果", isPresented: $showPendingAlert) {
                Button("直接导入") {
                    extracted = pendingCourses
                    showPreview = true
                }
                Button("继续提取") {}
            } message: {
                Text(pendingMessage)
            }
        }
        .onAppear { boundSchoolId = school.id }
    }

    private func triggerExtract() {
        extracting = true
        errorMessage = nil
        errorDiagText = nil
        NotificationCenter.default.post(name: .jiaowuExtract, object: nil)
    }

    private static func parityName(_ odd: Bool) -> String { odd ? "单周" : "双周" }

    /// 抽取结果分派：
    /// - 页面周次在具体某周（diag.week 非空）→ 单双周两段式流程（暂存/合并）
    /// - 全周视图（week 为空）→ 直接进预览（parity 已按周次文本推断）
    private func handleExtracted(_ courses: [Course], diag: ExtractResult.Diag?) {
        extracting = false
        if courses.isEmpty {
            errorDiagText = diag.map {
                "tables=\($0.tables ?? -1) header=\($0.header == true) sections=\($0.sections ?? -1) week=\($0.week.map(String.init) ?? "nil") cas=\($0.cas == true)"
            }
            errorMessage = Self.diagnoseMessage(diag)
            return
        }
        guard let wk = diag?.week, wk >= 1 else {
            // 没切周次（全周视图）：按旧流程直接进预览
            extracted = courses
            showPreview = true
            return
        }
        let odd = wk % 2 == 1
        if let pw = pendingContextWeek {
            if pw % 2 == wk % 2 {
                // 又提了同一奇偶的周次：替换暂存
                pendingCourses = courses
                let other = odd ? "双" : "单"
                let hint = odd ? wk + 1 : wk - 1
                pendingMessage = "已更新为第\(wk)周（\(Self.parityName(odd))）的提取结果，共 \(courses.count) 门课。\n请在网页里把周次切到另一个周次（如第\(hint)周，\(other)周）后再点「提取课表」，将自动合并成完整课表。"
                showPendingAlert = true
            } else {
                // 奇偶互补：合并成完整课表
                let merged = SchoolCatalog.mergeCourses(pendingCourses, courses)
                pendingCourses = []
                pendingContextWeek = nil
                extracted = merged
                showPreview = true
            }
        } else {
            // 第一段：暂存
            pendingCourses = courses
            pendingContextWeek = wk
            let other = odd ? "双" : "单"
            let hint = odd ? wk + 1 : wk - 1
            pendingMessage = "已暂存第\(wk)周（\(Self.parityName(odd))）的 \(courses.count) 门课。\n推荐：在网页里把周次切到第\(hint)周（\(other)周）再点「提取课表」，自动合并出完整课表。\n也可以点「直接导入」只导入本周次的课程。"
            showPendingAlert = true
        }
    }

    /// 按诊断数字给可行动的提示，替代以前那句永远一样的「没从当前页抽到课表」
    private static func diagnoseMessage(_ d: ExtractResult.Diag?) -> String {
        guard let d else {
            return "没从当前页抽到课表。请先在网页里点进「课表/我的课表」，再点「提取课表」。"
        }
        if d.cas == true {
            return "还没登录教务系统：请先在网页里完成登录（学号、密码、验证码），登录后会自动跳到课表页。"
        }
        if d.header != true {
            return "当前页没找到课表表格（诊断：表格 \(d.tables ?? 0) 个）。请先点进「课表/我的课表」再提取；如果已经在课表页，请点「复制诊断」反馈。"
        }
        if (d.sections ?? 0) == 0 {
            return "找到了课表表格，但没读到课程行——页面可能还没加载完。请等课程格子显示出来后再点一次「提取课表」。"
        }
        return "表格读到了但没解析出课程（节次行 \(d.sections ?? 0) 行）。请点「复制诊断」反馈，凭诊断可精确定位。"
    }

    // 教务凭据（CAS 验证码无法自动登录，自动填充后用户每次只需输验证码）
    private var accountSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("学号", text: $sidInput)
                    SecureField("密码", text: $pwdInput)
                } header: {
                    Text("教务账号（仅存本机，登录页自动填充）")
                } footer: {
                    Text("保存后打开登录页会自动填入学号和密码，验证码仍需手动输入。")
                }
                Section {
                    Button("保存") {
                        JiaoWuStore.saveStudent(sidInput, pwdInput)
                        showAccountSheet = false
                    }
                    .disabled(sidInput.isEmpty)
                    if JiaoWuStore.hasStudent() {
                        Button("清除已保存的账号", role: .destructive) {
                            JiaoWuStore.clearStudent()
                            sidInput = ""
                            pwdInput = ""
                        }
                    }
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
    let school: School
    let onExtracted: ([Course], ExtractResult.Diag?) -> Void
    let onError: (String) -> Void

    func makeCoordinator() -> JiaoWuCoordinator {
        JiaoWuCoordinator(school: school, onExtracted: onExtracted, onError: onError)
    }

    func makeUIViewController(context: Context) -> JiaoWuVC {
        let vc = JiaoWuVC()
        vc.school = school
        vc.coordinator = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: JiaoWuVC, context: Context) {}
}

final class JiaoWuVC: UIViewController, WKNavigationDelegate {
    var school: School!
    var coordinator: JiaoWuCoordinator!
    private var webView: WKWebView!
    /// 自动跳课表页尝试次数（会话失效时防和教务域乒乓，上限 3）
    private var autoNavTries = 0
    /// 自动抽取只做一轮（内含最多 2 次重试）；之后交给用户手动点「提取课表」
    private var didAutoExtract = false

    override func viewDidLoad() {
        super.viewDidLoad()
        let cfg = WKWebViewConfiguration()
        // 允许 CAS 回跳的 cookie / 会话驻留（默认 WKWebsiteDataStore 即足够）
        webView = WKWebView(frame: view.bounds, configuration: cfg)
        webView.navigationDelegate = self
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView.allowsBackForwardNavigationGestures = true
        view.addSubview(webView)
        webView.load(URLRequest(url: URL(string: school.loginBaseURL)!))
        NotificationCenter.default.addObserver(
            self, selector: #selector(doExtract), name: .jiaowuExtract, object: nil)
    }

    /// 手动「提取课表」入口。未登录拦截：不在教务域（多半还在 CAS 登录页）直接提示，
    /// 不再让抽取 JS 跑空、弹误导性的「提取失败」。
    @objc private func doExtract() {
        let jwHost = URL(string: school.loginBaseURL)?.host
        guard webView.url?.host == jwHost else {
            extractingGuard()
            return
        }
        coordinator.extract(from: webView)
    }

    private func extractingGuard() {
        coordinator.onError("还没登录教务系统：请先在网页里完成登录（学号、密码、验证码），再点「提取课表」。")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// 登录完成后自动跳课表页并自动抽一轮。
    /// 判据用「落在教务域」而不是「见过 CAS」：老会话直接进教务域也要自动跳；
    /// 而首次加载教务域若被重定向到 CAS（未登录），courseListURL 会作为 CAS 的
    /// service 参数，登录成功后直接落回课表页，少一次手动导航。
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let url = webView.url else { return }
        let jwHost = URL(string: school.loginBaseURL)?.host
        guard url.host == jwHost else {
            // 非教务域 ≈ CAS 登录页：有记住的凭据就自动填（只填空字段，幂等、不覆盖用户输入）
            autofillCredentials(webView)
            return
        }
        if !isCoursePage(url) {
            // 还没到课表页：自动跳过去（有次数上限，防会话失效时乒乓）
            guard autoNavTries < 3,
                  let courseURL = school.courseListURL.flatMap(URL.init(string:)) else { return }
            autoNavTries += 1
            webView.load(URLRequest(url: courseURL))
            return
        }
        // 已在课表页：自动抽一轮。金智页面可能有异步渲染（框架先出、课程后到），
        // 抽到空会由 Coordinator 自动重试（最多 2 次），耗尽才报错。
        guard !didAutoExtract else { return }
        didAutoExtract = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self else { return }
            self.coordinator.extract(from: webView, isAuto: true)
        }
    }

    /// 往 CAS 登录页注入记住的学号/密码。只填空字段：用户改过就不动，验证码永远不碰。
    /// React 类登录框直接赋 value 会被框架覆写，所以走原生 setter + input/change 事件。
    private func autofillCredentials(_ webView: WKWebView) {
        guard let acct = JiaoWuStore.loadStudent() else { return }
        func jsLiteral(_ s: String) -> String {
            guard let d = try? JSONEncoder().encode(s),
                  let q = String(data: d, encoding: .utf8) else { return "''" }
            return q   // JSON 字符串字面量是合法 JS 表达式
        }
        let script = """
        (function(){
          function fill(sel, v){
            var el = document.querySelector(sel);
            if (!el || el.value) return false;
            var d = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(el), 'value');
            if (d && d.set) d.set.call(el, v); else el.value = v;
            el.dispatchEvent(new Event('input', {bubbles:true}));
            el.dispatchEvent(new Event('change', {bubbles:true}));
            return true;
          }
          var a = fill('#username, input[name="username"]', __SID__);
          var b = fill('#password, input[name="password"]', __PWD__);
          return JSON.stringify({u:a, p:b});
        })()
        """.replacingOccurrences(of: "__SID__", with: jsLiteral(acct.sid))
            .replacingOccurrences(of: "__PWD__", with: jsLiteral(acct.pwd))
        webView.evaluateJavaScript(script) { _, _ in }
    }

    private func isCoursePage(_ url: URL) -> Bool {
        guard let coursePath = school.courseListURL.flatMap(URL.init(string:))?.path,
              !coursePath.isEmpty else { return false }
        return url.path == coursePath
    }

    // 调试：登录跳转过程中若失败可在此观察
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        NSLog("[JiaoWu] 导航失败: %@", error.localizedDescription)
    }
}

final class JiaoWuCoordinator {
    private let school: School
    private let onExtracted: ([Course], ExtractResult.Diag?) -> Void
    private let onError: (String) -> Void
    /// 自动抽取重试计数：金智课表格子可能异步渲染，首抽为空时延时再试
    private var autoAttempts = 0

    init(school: School, onExtracted: @escaping ([Course], ExtractResult.Diag?) -> Void, onError: @escaping (String) -> Void) {
        self.school = school
        self.onExtracted = onExtracted
        self.onError = onError
    }

    func extract(from webView: WKWebView, isAuto: Bool = false) {
        if !isAuto { autoAttempts = 0 }
        webView.evaluateJavaScript(school.extractorJS) { [weak self] result, error in
            guard let self else { return }
            if let error {
                DispatchQueue.main.async {
                    self.onError("课表抽取失败：\(error.localizedDescription)")
                }
                return
            }
            // extractorJS 返回 JSON 字符串 {courses:[…], diag:{…}}；解不出来 = 不在课表页
            guard let str = result as? String,
                  let data = str.data(using: .utf8),
                  let obj = try? JSONDecoder().decode(ExtractResult.self, from: data) else {
                DispatchQueue.main.async {
                    self.onError("课表页结构未识别（请确认已打开课表页）。")
                }
                return
            }
            let courses = SchoolCatalog.mapCourses(obj.courses)
            // 自动抽取为空且还有重试额度：静默延时重试（课程格子可能还没渲染完）
            if courses.isEmpty && isAuto && autoAttempts < 2 {
                autoAttempts += 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self, weak webView] in
                    guard let self, let webView else { return }
                    self.extract(from: webView, isAuto: true)
                }
                return
            }
            DispatchQueue.main.async {
                self.onExtracted(courses, obj.diag)
            }
        }
    }
}
