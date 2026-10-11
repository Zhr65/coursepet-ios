// MARK: - 扫一扫（「一扫」式：扫二维码/快递条码 → 直达目标 App / 复制内容）
// 链路：AVFoundation 扫码（.qr + .ean13 + .code128，快递面单条码也能扫）
//      → ScanPayloadRouter 按内容分类（App 深链 / 网页 / WiFi / 纯文本）
//      → 结果面板给主操作（打开/复制），继续扫可无缝回到取景。
// 入口：事务页左上角按钮 + coursepet://scan 深链（锁屏小组件 / Siri 快捷指令）。
import AVFoundation
import SwiftUI
import UIKit

// MARK: - 扫码结果分类
enum ScanPayload: Equatable {
    case appScheme(URL)                          // weixin:// alipays:// tbopen:// tel: 等自定义 scheme
    case web(URL)                                // http(s)：通用链接，微信/支付宝/淘宝域名经 Universal Link 直达 App
    case wifi(ssid: String, password: String?)   // WIFI:S:...;P:...;; 宿舍网二维码
    case text(String)                            // 取件码 / 纯文本

    var kindLabel: String {
        switch self {
        case .appScheme: return "App 深链"
        case .web:       return "网页链接"
        case .wifi:      return "Wi-Fi 网络"
        case .text:      return "文本内容"
        }
    }

    var icon: String {
        switch self {
        case .appScheme: return "arrow.up.forward.app"
        case .web:       return "safari"
        case .wifi:      return "wifi"
        case .text:      return "doc.text"
        }
    }

    var tint: Color {
        switch self {
        case .appScheme: return .green
        case .web:       return .blue
        case .wifi:      return .cyan
        case .text:      return .indigo
        }
    }

    var primaryTitle: String {
        switch self {
        case .appScheme: return "打开 App"
        case .web:       return "打开链接"
        case .wifi(_, let password): return password == nil ? "复制网络名" : "复制密码"
        case .text:      return "复制内容"
        }
    }
}

// MARK: - 内容路由器（纯函数，方便单测）
enum ScanPayloadRouter {
    static func classify(_ raw: String) -> ScanPayload {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .text(trimmed) }
        if trimmed.uppercased().hasPrefix("WIFI:") {
            return parseWifi(trimmed) ?? .text(trimmed)
        }
        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
           !scheme.isEmpty, scheme.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" }) {
            if scheme == "http" || scheme == "https" { return .web(url) }
            // 自定义 scheme 一律按深链直接 open（不要用 canOpenURL 门禁：
            // 未声明进 LSApplicationQueriesSchemes 的 scheme canOpenURL 恒 false，
            // 而 open 不需要声明，失败走回调兜底）
            return .appScheme(url)
        }
        return .text(trimmed)
    }

    /// 解析 WIFI:S:ssid;T:WPA;P:pass;H:false;; —— 值里的 ; , : \ 用反斜杠转义
    /// T:nopass 时没有 P 字段（开放网络）
    private static func parseWifi(_ raw: String) -> ScanPayload? {
        let body = String(raw.dropFirst(5))
        // 按未转义的 ; 切字段（保留转义符到值里再还原）
        var pairs: [String] = []
        var current = ""
        var escaped = false
        for ch in body {
            if escaped { current.append(ch); escaped = false; continue }
            if ch == "\\" { current.append(ch); escaped = true; continue }
            if ch == ";" { pairs.append(current); current = ""; continue }
            current.append(ch)
        }
        if !current.isEmpty { pairs.append(current) }

        var fields: [String: String] = [:]
        for pair in pairs {
            guard let sep = pair.firstIndex(of: ":") else { continue }
            let key = String(pair[..<sep]).uppercased()
            let value = unescape(String(pair[pair.index(after: sep)...]))
            fields[key] = value
        }
        guard let ssid = fields["S"], !ssid.isEmpty else { return nil }
        return .wifi(ssid: ssid, password: fields["P"])
    }

    private static func unescape(_ value: String) -> String {
        var out = ""
        var escaped = false
        for ch in value {
            if escaped { out.append(ch); escaped = false; continue }
            if ch == "\\" { escaped = true; continue }
            out.append(ch)
        }
        if escaped { out.append("\\") }
        return out
    }
}

// MARK: - 相机扫码控制器（AVFoundation）
// session 配置与 startRunning 是同步阻塞（最坏可到秒级），全部丢到专用串行队列，
// 主线程只负责 previewLayer 与回调。
final class QRScanController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onPayload: ((String) -> Void)?
    var onError: ((String) -> Void)?
    /// metadata 输出对应的 connection：暂停/恢复扫码用的就是 connection.isEnabled
    /// （AVCaptureMetadataOutput 本身没有 isMetadataOutputEnabled 这种开关）
    private var metadataConnection: AVCaptureConnection?

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "coursepet.scan.session")
    private var device: AVCaptureDevice?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.frame = view.bounds
        view.layer.insertSublayer(previewLayer, at: 0)
        sessionQueue.async { self.configureAndStart() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        view.layer.sublayers?.first?.frame = view.bounds
    }

    private func configureAndStart() {
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            DispatchQueue.main.async { self.onError?("没有可用的摄像头") }
            return
        }
        do {
            let input = try AVCaptureDeviceInput(device: camera)
            let output = AVCaptureMetadataOutput()
            session.beginConfiguration()
            session.addInput(input)
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: sessionQueue)
            // .qr 之外带上 .ean13/.code128：快递面单一维码也能扫（取件场景高频）
            output.metadataObjectTypes = [.qr, .ean13, .code128]
            session.commitConfiguration()
            device = camera
            metadataConnection = output.connections.first
            if !session.isRunning { session.startRunning() }
        } catch {
            DispatchQueue.main.async { self.onError?("摄像头初始化失败：\(error.localizedDescription)") }
        }
    }

    func start() {
        sessionQueue.async {
            guard self.metadataConnection != nil else { return }
            if !self.session.isRunning { self.session.startRunning() }
        }
    }

    func stop() {
        sessionQueue.async {
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    /// 继续扫：恢复 metadata 输出（结果面板关闭时调用）
    func resume() {
        sessionQueue.async {
            self.metadataConnection?.isEnabled = true
        }
    }

    func setTorch(_ on: Bool) {
        sessionQueue.async {
            guard let device = self.device, device.hasTorch else { return }
            try? device.lockForConfiguration()
            device.torchMode = on ? .on : .off
            device.unlockForConfiguration()
        }
    }

    // 命中回调在 sessionQueue 上；防抖不用定时器——直接关 connection，
    // 等结果面板关闭（继续扫）再恢复，杜绝同码连发
    func metadataOutput(_ output: AVCaptureMetadataOutput,
                        didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        guard connection.isEnabled,
              let obj = metadataObjects.compactMap({ $0 as? AVMetadataMachineReadableCodeObject }).first,
              let value = obj.stringValue, !value.isEmpty else { return }
        connection.isEnabled = false
        DispatchQueue.main.async { self.onPayload?(value) }
    }
}

// MARK: - SwiftUI 包装
struct CameraScannerView: UIViewControllerRepresentable {
    let onPayload: (String) -> Void
    let onError: (String) -> Void
    let onReady: (QRScanController) -> Void

    func makeUIViewController(context: Context) -> QRScanController {
        let controller = QRScanController()
        controller.onPayload = onPayload
        controller.onError = onError
        // onReady 异步派发：makeUIViewController 期间同步改 SwiftUI @State 会报
        // "Modifying state during view update"
        DispatchQueue.main.async { self.onReady(controller) }
        return controller
    }

    func updateUIViewController(_ uiViewController: QRScanController, context: Context) {}

    static func dismantleUIViewController(_ uiViewController: QRScanController, coordinator: ()) {
        uiViewController.stop()
    }
}

// MARK: - 扫码页
struct ScanCodeView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @State private var authorization = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var controller: QRScanController?
    @State private var torchOn = false
    @State private var rawText = ""
    @State private var payload: ScanPayload?
    @State private var scannerError: String?
    @State private var toast: String?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch authorization {
            case .authorized:
                CameraScannerView(
                    onPayload: handleScan,
                    onError: { scannerError = $0 },
                    onReady: { controller = $0 })
                    .ignoresSafeArea()
                reticle
            case .notDetermined:
                ProgressView("正在申请相机权限…")
                    .tint(.white)
                    .onAppear { requestCamera() }
            default:
                permissionDenied
            }

            VStack(spacing: 0) {
                topBar
                Spacer()
                if let payload { resultCard(payload) }
            }
            if let toast { toastView(toast) }
        }
        .onChange(of: torchOn) { controller?.setTorch($0) }
        .onChange(of: scenePhase) { phase in
            // 退后台必须停 session（省电 + 相机指示灯熄灭）；回前台且没在看结果时恢复
            guard authorization == .authorized else { return }
            if phase == .active, payload == nil { controller?.start() }
            if phase == .background { controller?.stop() }
        }
        .onDisappear {
            controller?.stop()
            controller?.setTorch(false)
        }
    }

    // MARK: 顶部控件
    private var topBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 28))
                    .foregroundColor(.white.opacity(0.85))
            }
            Spacer()
            Button { torchOn.toggle() } label: {
                Image(systemName: torchOn ? "flashlight.on.fill" : "flashlight.off.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(torchOn ? .yellow : .white.opacity(0.85))
                    .padding(8)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .disabled(authorization != .authorized)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    // MARK: 取景框
    private var reticle: some View {
        VStack(spacing: 14) {
            Spacer()
            RoundedRectangle(cornerRadius: 18)
                .stroke(Color.white.opacity(0.85), lineWidth: 2)
                .frame(width: 260, height: 260)
            Text("对准二维码 / 快递条码")
                .font(.footnote)
                .foregroundColor(.white.opacity(0.8))
            Spacer()
        }
    }

    // MARK: 权限被拒
    private var permissionDenied: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.badge.ellipsis")
                .font(.system(size: 44))
                .foregroundColor(.gray)
            Text("需要相机权限才能扫码")
                .foregroundColor(.white)
            Text("设置 → CoursePet → 打开相机开关")
                .font(.footnote)
                .foregroundColor(.gray)
            Button("去设置") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    // MARK: 结果面板
    private func resultCard(_ payload: ScanPayload) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: payload.icon)
                    .foregroundColor(payload.tint)
                Text(payload.kindLabel)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.secondary)
                Spacer()
                Button("继续扫") { resumeScanning() }
                    .font(.subheadline)
            }
            if case .wifi(let ssid, let password) = payload {
                Text("网络：\(ssid)\n密码：\(password ?? "（开放网络，无需密码）")")
                    .font(.subheadline.weight(.medium))
                    .textSelection(.enabled)
            }
            ScrollView {
                Text(rawText)
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 88)
            HStack(spacing: 10) {
                Button { runPrimary(payload) } label: {
                    Label(payload.primaryTitle, systemImage: payload.icon)
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(payload.tint)
                Button {
                    UIPasteboard.general.string = rawText
                    showToast("已复制")
                } label: {
                    Image(systemName: "doc.on.doc")
                        .frame(width: 44, height: 38)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private func toastView(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text)
                .font(.footnote.weight(.medium))
                .foregroundColor(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Capsule().fill(Color.black.opacity(0.75)))
                .padding(.bottom, 120)
        }
        .allowsHitTesting(false)
    }

    // MARK: 动作
    private func requestCamera() {
        AVCaptureDevice.requestAccess(for: .video) { granted in
            DispatchQueue.main.async {
                // 授权后 body 切到 authorized 分支，新 controller 创建时自动 configureAndStart
                authorization = granted ? .authorized : .denied
            }
        }
    }

    private func handleScan(_ raw: String) {
        rawText = raw
        payload = ScanPayloadRouter.classify(raw)
    }

    private func resumeScanning() {
        payload = nil
        rawText = ""
        controller?.resume()
    }

    private func runPrimary(_ payload: ScanPayload) {
        switch payload {
        case .appScheme(let url):
            if url.scheme?.lowercased() == "coursepet" {
                // 自己的深链（比如扫到小组件打印的码）：内部路由 + 关页
                NotificationCenter.default.post(
                    name: .coursepetOpenNotificationRoute,
                    object: nil,
                    userInfo: ["url": url])
                dismiss()
            } else {
                open(url)
            }
        case .web(let url):
            // 微信/支付宝/淘宝域名的通用链接 open 即直达 App（系统 Universal Link 路由），否则落 Safari
            open(url)
        case .wifi(_, let password):
            UIPasteboard.general.string = password ?? rawText
            showToast(password == nil ? "已复制网络名" : "已复制密码")
        case .text:
            UIPasteboard.general.string = rawText
            showToast("已复制")
        }
    }

    private func open(_ url: URL) {
        UIApplication.shared.open(url) { ok in
            if !ok { showToast("打不开这个目标，试试复制后手动粘贴") }
        }
    }

    private func showToast(_ text: String) {
        toast = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            if toast == text { toast = nil }
        }
    }
}
