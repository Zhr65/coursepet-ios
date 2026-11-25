// MARK: - 学校教务登录 + 课表导入（端侧 WebView 直连）
// 链路：WebView 加载教务系统(jw.xjit.edu.cn) → 未登录自动跳 CAS(cas.xjit.edu.cn) →
//       已记住凭据时自动填学号/密码（注入到每个 frame + 轮询 20×0.5s，覆盖
//       iframe 内的登录框和 JS 后插入的输入框；验证码仍需手动输，CAS 无法绕过）→
//       用户登录 → CAS 回跳建立会话 → didFinish 发现落在教务域且页面已无密码框 → 自动跳课表页(xskb_list.do)
//       → 自动抽课表（最多 2 次机会 0.8s/1.6s：金智部分渲染是异步的）→
//       抽取结果走 CourseImportConfirmView 预览 → 导入 DataManager。
// 未登录绝不报错（2026-11-25）：金智的 xskb_list.do 会话失效时 URL 不变、内容变登录页，
//   旧逻辑只看 host+path 就自动抽取 → 0 门课 → 弹「提取失败」，用户看到的是
//   「刚进去还没登录就说导入失败」。现在先探「页面有没有可见密码框」判登录态，
//   自动抽取的任何失败（JS 报错 / 结构不识别 / 抽到空）一律静默，只有用户手动点
//   「导入课表」才给完整诊断。
// 单双周两段式提取（2026-10-17）：学校课表格子把单双周课混在一起，周次文本无单双周信息。
//   用户在网页里把周次切到某单周（如第3周）→ 提取（全部课标 single，暂存）→
//   切到双周（如第4周）→ 再提取 → 自动合并成完整课表进预览。只提一次也能直接导入。
//   页面没切周次（全周视图）时 parity 按周次文本推断（全奇/全偶仍能判出）。
// 诊断：抽取 JS 总是返回页面结构诊断（表格数/表头/节次行/周次/CAS），失败弹窗展示 +
//   「复制诊断」按钮，真机问题可凭诊断数字远程定位，不用再盲猜。
// 凭据只存手机 Keychain（JiaoWuStore），不传服务器；Keychain 不可用时降级 UserDefaults。
import SwiftUI
import WebKit
import UIKit

extension Notification.Name {
    /// JiaoWuLoginView 点「导入课表」→ 通知 WebView 容器执行 JS 抽取
    static let jiaowuExtract = Notification.Name("jiaowu.extract")
    /// 用户在「记住学号」里刚保存了凭据 → 通知 WebView 容器立刻回填当前登录页
    static let jiaowuAutofill = Notification.Name("jiaowu.autofill")
}

struct JiaoWuLoginView: View {
    let school: School
    @Environment(\.dismiss) private var dismiss

    @State private var extracting = false
    @State private var extracted: [Course] = []
    @State private var errorMessage: String?
    /// 弹窗标题：未登录导致的拦截不该顶着「提取失败」——用户什么都没点错，
    /// 告诉他「还没登录」比「失败了」准确得多
    @State private var errorTitle = "提取失败"
    /// 最近一次失败的诊断串（「复制诊断」按钮往剪贴板放的就是它）
    @State private var errorDiagText: String?
    @State private var showPreview = false
    @State private var showAccountSheet = false
    @State private var sidInput = ""
    @State private var pwdInput = ""
    /// 「记住学号」保存失败提示（Keychain + UserDefaults 双写都没成，极罕见）
    @State private var accountSaveError: String?
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
                        errorTitle = (msg.contains("还没登录") || msg.contains("登录框"))
                            ? "还没登录" : "提取失败"
                        errorMessage = msg
                    }
                )
                .ignoresSafeArea()

                if extracting {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("正在读取课表…").font(.caption).foregroundColor(.secondary)
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
                    Button("导入课表") { triggerExtract() }
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
            .alert(errorTitle, isPresented: Binding(
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
            let msg = Self.diagnoseMessage(diag)
            // 只有「还没登录」这一类失败改标题；解析类失败仍叫「提取失败」
            errorTitle = msg.contains("还没登录") ? "还没登录" : "提取失败"
            errorMessage = msg
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
                pendingMessage = "已更新为第\(wk)周（\(Self.parityName(odd))）的提取结果，共 \(courses.count) 门课。\n请在网页里把周次切到另一个周次（如第\(hint)周，\(other)周）后再点「导入课表」，将自动合并成完整课表。"
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
            pendingMessage = "已暂存第\(wk)周（\(Self.parityName(odd))）的 \(courses.count) 门课。\n推荐：在网页里把周次切到第\(hint)周（\(other)周）再点「导入课表」，自动合并出完整课表。\n也可以点「直接导入」只导入本周次的课程。"
            showPendingAlert = true
        }
    }

    /// 按诊断数字给可行动的提示，替代以前那句永远一样的「没从当前页抽到课表」
    private static func diagnoseMessage(_ d: ExtractResult.Diag?) -> String {
        guard let d else {
            return "没从当前页抽到课表。请先在网页里点进「课表/我的课表」，再点「导入课表」。"
        }
        if d.cas == true {
            return "还没登录教务系统：请先在网页里完成登录（学号、密码、验证码），登录后会自动跳到课表页。"
        }
        if d.header != true {
            return "当前页没找到课表表格（诊断：表格 \(d.tables ?? 0) 个）。请先点进「课表/我的课表」再提取；如果已经在课表页，请点「复制诊断」反馈。"
        }
        if (d.sections ?? 0) == 0 {
            return "找到了课表表格，但没读到课程行——页面可能还没加载完。请等课程格子显示出来后再点一次「导入课表」。"
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
                    Text("保存后会自动填进登录页的学号和密码（登录框在页面内嵌 iframe 里也能填），验证码仍需手动输入。凭据只存本机。")
                }
                Section {
                    Button("保存") {
                        accountSaveError = nil
                        if JiaoWuStore.saveStudent(sidInput, pwdInput) {
                            showAccountSheet = false
                            // 保存完立刻回填当前登录页，不用等下次 didFinish
                            NotificationCenter.default.post(name: .jiaowuAutofill, object: nil)
                        } else {
                            accountSaveError = "保存失败：系统钥匙串和本地存储都没写成功。请重试，或先手动在登录页输入一次。"
                        }
                    }
                    .disabled(sidInput.isEmpty)
                    if let accountSaveError {
                        Text(accountSaveError)
                            .font(.footnote)
                            .foregroundColor(.red)
                    }
                    if JiaoWuStore.hasStudent() {
                        Button("清除已保存的账号", role: .destructive) {
                            JiaoWuStore.clearStudent()
                            sidInput = ""
                            pwdInput = ""
                            accountSaveError = nil
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
    /// 课表页自动抽取次数（上限 2）。原来是「只抽一次」的布尔开关：
    /// 首次进入常常是「会话已失效」提示页（URL 停在课表页、内容是登录/提示），
    /// 静默失败后用户登录、回跳到课表页，布尔已是 true 就再也不自动抽——
    /// 表现为「必须手动点一下提取」。
    private var autoExtractCount = 0
    /// 自动填充轮次（同页最多 6 轮 × 0.4s）。很多 CAS 登录页先出骨架、后插输入框，
    /// didFinish 那一刻 input 还不存在，只填一次必然落空。
    private var autofillRound = 0
    private var autofillURL: String?

    /// 页面是不是还停在登录框（有可见密码框 = 没登录）。
    /// 必须探这一下：金智 jsxsd 的 xskb_list.do 在会话失效时 URL 不变、
    /// 内容换成登录/提示页，只看 host + path 会把未登录误判成课表页，
    /// 接着自动抽取 0 门课、弹出「提取失败」——用户看到的就是「还没登录就说导入失败」。
    static let loginProbeJS = """
    (function(){
      var els = document.querySelectorAll('input[type=password]');
      for (var i = 0; i < els.length; i++) {
        var r = els[i].getBoundingClientRect();
        if (r.width > 0 && r.height > 0) return 1;
      }
      return 0;
    })()
    """

    override func viewDidLoad() {
        super.viewDidLoad()
        let cfg = WKWebViewConfiguration()
        // 脚本必须在 WKWebView 初始化之前挂进 configuration——created 之后的修改
        // 对首次加载不保证生效（配置项会随 init 固化）
        if let src = Self.autofillSource(for: JiaoWuStore.loadStudent()) {
            cfg.userContentController.addUserScript(
                WKUserScript(source: src, injectionTime: .atDocumentEnd, forMainFrameOnly: false))
        }
        // 允许 CAS 回跳的 cookie / 会话驻留（默认 WKWebsiteDataStore 即足够）
        webView = WKWebView(frame: view.bounds, configuration: cfg)
        webView.navigationDelegate = self
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView.allowsBackForwardNavigationGestures = true
        view.addSubview(webView)
        webView.load(URLRequest(url: URL(string: school.loginBaseURL)!))
        NotificationCenter.default.addObserver(
            self, selector: #selector(doExtract), name: .jiaowuExtract, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleAutofillNotice), name: .jiaowuAutofill, object: nil)
    }

    /// 用户在「记住学号」里刚保存：换注入脚本（下次导航生效）+ 立刻对当前页填一次（本次生效）
    @objc private func handleAutofillNotice() {
        autofillRound = 0
        autofillURL = nil
        refreshInjectedScript()
        autofillCredentials(webView)
    }

    /// 已创建的 webView 换注入脚本。removeAllUserScripts 在本工程安全（没有其他 user script）
    private func refreshInjectedScript() {
        let ucc = webView.configuration.userContentController
        ucc.removeAllUserScripts()
        if let src = Self.autofillSource(for: JiaoWuStore.loadStudent()) {
            ucc.addUserScript(WKUserScript(source: src, injectionTime: .atDocumentEnd,
                                          forMainFrameOnly: false))
        }
    }

    /// 生成注入脚本（nil = 没有可用凭据，不注入）。
    /// 为什么要注入到每个 frame：不少学校的门户把 CAS 登录框嵌在 iframe 里，
    /// 主框架 evaluateJavaScript 根本看不到那份 DOM；而登录框由 JS 后插入时，
    /// didFinish 那一刻还没有 input。脚本自带轮询（20 × 0.5s），填上就停，
    /// 把「iframe 填不到」和「还没渲染就填」两个失败原因一起解决。
    static func autofillSource(for account: (sid: String, pwd: String)?) -> String? {
        guard let account, !account.sid.isEmpty else { return nil }
        let body = autofillJS
            .replacingOccurrences(of: "__SID__", with: jsLiteral(account.sid))
            .replacingOccurrences(of: "__PWD__", with: jsLiteral(account.pwd))
        return """
        (function(){
          var tries = 0;
          function tick(){
            tries++;
            try {
              var r = \(body);
              if (r && r.indexOf('"done":true') >= 0) return;
            } catch(e){}
            if (tries < 20) setTimeout(tick, 500);
          }
          if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', tick);
          } else {
            tick();
          }
        })();
        """
    }

    /// JSON 字符串字面量是合法 JS 表达式（学号/密码里的引号、反斜杠都被正确转义）
    private static func jsLiteral(_ s: String) -> String {
        guard let d = try? JSONEncoder().encode(s),
              let q = String(data: d, encoding: .utf8) else { return "''" }
        return q
    }

    /// 手动「导入课表」入口：分两层拦截，别让抽取 JS 在登录页上空跑再报误导性的错。
    /// 1) 不在教务域（还在 CAS）→ 直接说没登录
    /// 2) 在教务域但页面仍是登录框 → 说清「还差哪一步」
    @objc private func doExtract() {
        let jwHost = URL(string: school.loginBaseURL)?.host
        guard webView.url?.host == jwHost else {
            coordinator.onError("还没登录教务系统：请先在网页里完成登录（学号、密码、验证码），再点「导入课表」。")
            return
        }
        webView.evaluateJavaScript(Self.loginProbeJS) { [weak self] result, _ in
            guard let self else { return }
            if Self.probeTrue(result) {
                self.coordinator.onError("当前页面还是登录框，没进课表。请把学号/密码/验证码填完点登录，等页面跳到课表后再点「导入课表」。")
                return
            }
            self.coordinator.extract(from: self.webView)
        }
    }

    /// JS 探测结果是 0/1（NSNumber 桥接）。Bool 也会桥接成 NSNumber，一并覆盖
    private static func probeTrue(_ result: Any?) -> Bool {
        (result as? NSNumber)?.boolValue ?? false
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// 每次导航完成分三路走：
    /// - 非教务域（CAS / 统一身份认证）→ 只回填凭据，绝不抽取、绝不自动导航
    /// - 教务域但仍是登录框（自己的登录页 / 会话失效页）→ 回填凭据，等用户登录
    /// - 教务域且已登录 → 不在课表页就先跳过去，在课表页就自动抽一轮
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let url = webView.url else { return }
        let jwHost = URL(string: school.loginBaseURL)?.host

        guard url.host == jwHost else {
            autofillCredentials(webView)
            return
        }

        webView.evaluateJavaScript(Self.loginProbeJS) { [weak self, weak webView] result, _ in
            guard let self, let webView else { return }
            if Self.probeTrue(result) {
                self.autofillCredentials(webView)
                return
            }
            if !self.isCoursePage(url) {
                // 还没到课表页：自动跳过去（有次数上限，防会话失效时乒乓）
                guard self.autoNavTries < 3,
                      let courseURL = self.school.courseListURL.flatMap(URL.init(string:)) else { return }
                self.autoNavTries += 1
                webView.load(URLRequest(url: courseURL))
                return
            }
            self.scheduleAutoExtract(webView)
        }
    }

    /// 课表页自动抽取：首次 0.8s（等异步渲染），第二次 1.6s（登录回跳后的慢加载）
    private func scheduleAutoExtract(_ webView: WKWebView) {
        guard autoExtractCount < 2 else { return }
        autoExtractCount += 1
        let delay: TimeInterval = autoExtractCount == 1 ? 0.8 : 1.6
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak webView] in
            guard let self, let webView else { return }
            self.coordinator.extract(from: webView, isAuto: true)
        }
    }

    /// 往登录页注入记住的学号/密码（验证码永远不碰）。只填空白字段：
    /// 用户改过的框不动，但会按 0.4s 间隔重试最多 6 轮——登录框大多是 JS 后插入的，
    /// didFinish 那一刻 DOM 里还没有 input，填一次必然落空，这就是「记住了却不自动填」。
    private func autofillCredentials(_ webView: WKWebView) {
        guard let acct = JiaoWuStore.loadStudent() else { return }
        let pageKey = webView.url?.absoluteString ?? ""
        if autofillURL != pageKey {     // 换页（CAS 回跳 / 登录后重定向）重置计数
            autofillURL = pageKey
            autofillRound = 0
        }
        guard autofillRound < 6 else { return }
        autofillRound += 1

        let script = Self.autofillJS
            .replacingOccurrences(of: "__SID__", with: Self.jsLiteral(acct.sid))
            .replacingOccurrences(of: "__PWD__", with: Self.jsLiteral(acct.pwd))
        webView.evaluateJavaScript(script) { [weak self, weak webView] result, _ in
            guard let self, let webView else { return }
            // 两个框都填上了就收工，否则 0.4s 后再试
            if let s = result as? String, s.contains("\"done\":true") { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                self.autofillCredentials(webView)
            }
        }
    }

    /// 泛化自动填充：不写死 #username/#password。
    /// 各校 CAS 的 id 完全不同（xjit 是 username，别的学校常见 #un / #loginName / #userCode /
    /// #account / name=stuno），写死选择器一半学校填不上；改成按 type + name/id/placeholder
    /// 关键字挑「唯一的密码框」和「像用户名的文本框」，验证码框按名字一律跳过。
    /// 直接赋 value 会被 React/Vue 的受控组件覆写，所以走原生 setter + input/change 事件。
    static let autofillJS = #"""
    (function(){
      function visible(el){
        try {
          var r = el.getBoundingClientRect();
          if (r.width <= 0 || r.height <= 0) return false;
          var st = window.getComputedStyle(el);
          return st.display !== 'none' && st.visibility !== 'hidden' && st.opacity !== '0';
        } catch(e){ return false; }
      }
      function setVal(el, v){
        if (el.value) return false;
        var d = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(el), 'value');
        if (d && d.set) d.set.call(el, v); else el.value = v;
        ['input','change','keyup','blur'].forEach(function(t){
          try { el.dispatchEvent(new Event(t, {bubbles:true})); } catch(e){}
        });
        return true;
      }
      var skipRe = /captcha|checkcode|verify|validate|vcode|yzm|smscode|msgcode|randcode|randomcode|authcode|imgcode|dynamic/i;
      var badType = {hidden:1, checkbox:1, radio:1, submit:1, button:1, image:1, file:1, reset:1, search:1, range:1, color:1};
      var inputs = Array.prototype.slice.call(document.querySelectorAll('input')).filter(function(el){
        return visible(el) && !badType[(el.type || 'text').toLowerCase()];
      });
      function keyOf(el){
        return ((el.name||'') + ' ' + (el.id||'') + ' ' + (el.placeholder||'') + ' ' +
                (el.getAttribute('autocomplete')||'')).toLowerCase();
      }
      var pwd = null, user = null;
      for (var i = 0; i < inputs.length; i++) {
        var el = inputs[i], k = keyOf(el);
        if (skipRe.test(k)) continue;
        if ((el.type || '').toLowerCase() === 'password') { if (!pwd) pwd = el; continue; }
        if (user) continue;
        if (/user|account|login|学号|账号|帐号|uname|loginname|uid|工号|stuno|student|sid/.test(k)
            || /^(text|tel)$/i.test(el.type || 'text') || !el.type) {
          user = el;
        }
      }
      var a = false, b = false;
      if (user) a = setVal(user, __SID__);
      if (pwd)  b = setVal(pwd,  __PWD__);
      // done 判定要覆盖三种页面：① 学号+密码都在（两个都填好才算完）
      // ② 分步登录只出了学号框（填上学号就够，别死等密码框）
      // ③ 一个框都还没渲染出来（done=false，继续轮询；这里若用「没框就算完」会立刻停，等于没填）
      var uok = !user || a || !!user.value;
      var pok = !pwd  || b || !!pwd.value;
      var done = (!!user || !!pwd) && uok && pok;
      return JSON.stringify({u: a, p: b, done: done, inputs: inputs.length});
    })()
    """#

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
    /// 非 private：JiaoWuVC.doExtract()（未登录 / 仍在登录框时的拦截提示）要经 coordinator
    /// 向 SwiftUI 层报错，收紧成 private 会直接编译失败。
    let onError: (String) -> Void
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
                // 自动抽取是登录后的顺手帮忙，失败不该打扰用户（此时他多半还没登录）
                if isAuto { return }
                DispatchQueue.main.async {
                    self.onError("课表抽取失败：\(error.localizedDescription)")
                }
                return
            }
            // extractorJS 返回 JSON 字符串 {courses:[…], diag:{…}}；解不出来 = 不在课表页
            guard let str = result as? String,
                  let data = str.data(using: .utf8),
                  let obj = try? JSONDecoder().decode(ExtractResult.self, from: data) else {
                if isAuto { return }
                DispatchQueue.main.async {
                    self.onError("课表页结构未识别（请确认已打开课表页）。")
                }
                return
            }
            let courses = SchoolCatalog.mapCourses(obj.courses)
            if courses.isEmpty && isAuto {
                // 自动抽取（登录后顺手帮一把）还有重试额度：课程格子可能还在渲染，静默再来一次
                if autoAttempts < 2 {
                    autoAttempts += 1
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self, weak webView] in
                        guard let self, let webView else { return }
                        self.extract(from: webView, isAuto: true)
                    }
                    return
                }
                // 重试耗尽仍然空 → 一律静默收工，绝不弹「提取失败」。
                // 触发空结果的原因太多：还没登录的会话失效页、CAS 回跳中间页、
                // 课表格子异步渲染慢、学校周末无课……用户此刻什么都没点，
                // 弹窗只会让他以为「刚进来就导入失败」。手动点「导入课表」时才给完整诊断。
                return
            }
            DispatchQueue.main.async {
                self.onExtracted(courses, obj.diag)
            }
        }
    }
}
