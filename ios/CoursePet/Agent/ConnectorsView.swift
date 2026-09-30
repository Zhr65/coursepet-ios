// MARK: - 连接器（Muse 式能力授权中心）
// "已连接" = 对应系统权限已授权，Agent 能用它；"可用" = 还没授权，点"连接"才弹系统授权窗。
// 被系统拒绝过（denied）的项不再重复弹窗，改引导跳系统设置开权限。
// 红线：绝不自动弹窗——只有用户点"连接"这个显式动作才触发请求。
// 自绘行（VStack）不嵌 List：本页既能单独用，也会作为页签塞进 PetAvatarSheet。
import SwiftUI
import EventKit
import UserNotifications
import CoreLocation
import CoreMotion
import AVFoundation
import Photos

struct ConnectorsView: View {
    // MARK: 连接器定义（全部对应项目真实功能，不凑数）
    private struct Connector: Identifiable {
        let id: String
        let name: String
        let icon: String      // SF Symbol
        let tint: Color       // 图标圆底色
        let blurb: String     // 给 Agent 什么能力
    }

    private let all: [Connector] = [
        Connector(id: "browser", name: "浏览器", icon: "globe", tint: .blue,
                  blurb: "联网搜索、阅读网页内容"),
        Connector(id: "calendar", name: "日历", icon: "calendar", tint: .red,
                  blurb: "读系统日程，回答安排时更有数"),
        Connector(id: "notifications", name: "通知", icon: "bell.badge", tint: .orange,
                  blurb: "课程提醒、DDL 轰炸、任务结果推送"),
        Connector(id: "location", name: "定位", icon: "location", tint: .green,
                  blurb: "到教学楼附近提醒下一节课"),
        Connector(id: "camera", name: "相机", icon: "camera", tint: .gray,
                  blurb: "拍照发给它看"),
        Connector(id: "photos", name: "相册", icon: "photo.on.rectangle", tint: .purple,
                  blurb: "从相册选图发给它看"),
        Connector(id: "microphone", name: "麦克风", icon: "mic", tint: .pink,
                  blurb: "按住说话，语音转文字聊天"),
        Connector(id: "health", name: "健康步数", icon: "figure.walk", tint: .mint,
                  blurb: "读每日步数，发里程碑奖励"),
    ]

    private enum Status { case connected, notDetermined, denied, unavailable }

    // MARK: 软件（连接第三方 App：已安装即可被 Agent 的 jump 卡片/这里拉起）
    private struct AppConnector: Identifiable {
        let id: String     // URL scheme（与 Info.plist LSApplicationQueriesSchemes 一一对应）
        let name: String
        let tint: Color
        let blurb: String
    }

    private let apps: [AppConnector] = [
        AppConnector(id: "meituanwaimai", name: "美团外卖", tint: .yellow,
                     blurb: "外卖跳转、取件提醒配合用"),
        AppConnector(id: "ctrip", name: "携程旅行", tint: .blue,
                     blurb: "假期回家订票直达"),
        AppConnector(id: "fliggy", name: "飞猪", tint: .orange,
                     blurb: "旅行票务跳转"),
        AppConnector(id: "taobao", name: "淘宝", tint: .orange,
                     blurb: "网购比价跳转"),
        AppConnector(id: "openapp.jdmobile", name: "京东", tint: .red,
                     blurb: "网购比价跳转"),
        AppConnector(id: "iosamap", name: "高德地图", tint: .cyan,
                     blurb: "导航去教室/提醒点"),
        AppConnector(id: "bilibili", name: "哔哩哔哩", tint: .pink,
                     blurb: "课程/学习视频跳转"),
        AppConnector(id: "orpheus", name: "网易云音乐", tint: .red,
                     blurb: "专注学习歌单跳转"),
    ]

    @State private var statuses: [String: Status] = [:]
    @State private var installedApps: [String: Bool] = [:]
    // 定位授权弹窗需要被持有的 manager（临时实例弹窗后 delegate 释放不可靠）
    @State private var locationManager = CLLocationManager()
    @State private var settingsHint = ""

    /// 显式空初始化器：private @State 会让合成的成员初始化器变 private，跨文件调用不保险
    init() { }

    var body: some View {
        // 不自带 ScrollView：作为页签嵌入 PetAvatarSheet 的 ScrollView 统一滚动，
        // 避免垂直嵌套滚动冲突（同轴双 ScrollView 手势会打架）
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("已连接")
            ForEach(all.filter { statuses[$0.id] == .connected }) { c in
                row(c, status: .connected)
            }
            if !all.contains(where: { statuses[$0.id] == .connected }) {
                emptyHint("还没有已连接的能力")
            }

            let pending = all.filter { statuses[$0.id] != .connected }
            if !pending.isEmpty {
                sectionHeader("可用").padding(.top, 8)
                ForEach(pending) { c in
                    row(c, status: statuses[c.id] ?? .notDetermined)
                }
            }

            // 软件：已安装的 Agent 可以直接拉起（跳外卖/订票/导航…）
            sectionHeader("软件").padding(.top, 8)
            ForEach(apps) { app in
                appRow(app)
            }
            Text("「已安装」的 App 可以被它的跳转卡片直接拉起；App 内的操作（下单、付款、登录）仍需你手动完成。")
                .font(.caption2)
                .foregroundColor(Color(.tertiaryLabel))
                .padding(.top, 4)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 24)
        .onAppear { refresh() }
        .alert("去系统设置开权限", isPresented: Binding(
            get: { !settingsHint.isEmpty },
            set: { if !$0 { settingsHint = "" } })) {
            Button("去设置") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text(settingsHint)
        }
    }

    // MARK: 分组头与行
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.footnote).fontWeight(.semibold)
            .foregroundColor(.secondary)
    }

    private func emptyHint(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundColor(Color(.tertiaryLabel))
    }

    private func row(_ c: Connector, status: Status) -> some View {
        HStack(spacing: 12) {
            Image(systemName: c.icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(.white)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 9).fill(c.tint))
            VStack(alignment: .leading, spacing: 2) {
                Text(c.name)
                    .font(.subheadline).fontWeight(.semibold)
                    .foregroundColor(.primary)
                Text(c.blurb)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            trailing(for: c, status: status)
        }
        .padding(.vertical, 6)
    }

    // MARK: 软件行（已安装可点击拉起；未安装灰态）
    private func appRow(_ app: AppConnector) -> some View {
        let installed = installedApps[app.id] == true
        return Button {
            if installed, let url = URL(string: "\(app.id)://") {
                UIApplication.shared.open(url)
            }
        } label: {
            HStack(spacing: 12) {
                Text(String(app.name.prefix(1)))
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 34, height: 34)
                    .background(RoundedRectangle(cornerRadius: 9).fill(app.tint))
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.name)
                        .font(.subheadline).fontWeight(.semibold)
                        .foregroundColor(.primary)
                    Text(app.blurb)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if installed {
                    Label("打开", systemImage: "arrow.up.right")
                        .font(.caption).fontWeight(.medium)
                        .foregroundColor(.indigo)
                } else {
                    Text("未安装")
                        .font(.caption)
                        .foregroundColor(Color(.tertiaryLabel))
                }
            }
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .disabled(!installed)
    }

    @ViewBuilder
    private func trailing(for c: Connector, status: Status) -> some View {
        switch status {
        case .connected:
            Label("已连接", systemImage: "checkmark")
                .font(.caption).fontWeight(.medium)
                .foregroundColor(.green)
        case .notDetermined:
            Button {
                request(c)
            } label: {
                Text("连接")
                    .font(.subheadline).fontWeight(.semibold)
            }
        case .denied:
            Button {
                settingsHint = "「\(c.name)」权限之前被拒绝了，需要到系统设置里手动打开。"
            } label: {
                Text("去设置")
                    .font(.subheadline).fontWeight(.semibold)
            }
        case .unavailable:
            Text("不可用")
                .font(.caption)
                .foregroundColor(Color(.tertiaryLabel))
        }
    }

    // MARK: 状态检测
    private func refresh() {
        var s: [String: Status] = ["browser": .connected]   // 网页阅读无系统权限门槛
        // 日历（复用 EventKitManager 的 iOS 17 fullAccess / 16 authorized 兼容判断）
        s["calendar"] = EventKitManager.isAuthorized ? .connected
            : (EKEventStore.authorizationStatus(for: .event) == .denied ? .denied : .notDetermined)
        // 通知
        let nc = UNUserNotificationCenter.current()
        s["notifications"] = .notDetermined   // 先占位，异步补
        nc.getNotificationSettings { settings in
            DispatchQueue.main.async {
                statuses["notifications"] = mapAuth(settings.authorizationStatus)
            }
        }
        // 定位
        switch CLLocationManager().authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways: s["location"] = .connected
        case .denied, .restricted: s["location"] = .denied
        default: s["location"] = .notDetermined
        }
        // 相机
        s["camera"] = mapAuth(AVCaptureDevice.authorizationStatus(for: .video))
        // 相册
        s["photos"] = mapAuth(PHPhotoLibrary.authorizationStatus(for: .readWrite))
        // 麦克风（老 API，iOS 16.1 红线内可用）
        switch AVAudioSession.sharedInstance().recordPermission {
        case .granted: s["microphone"] = .connected
        case .denied: s["microphone"] = .denied
        default: s["microphone"] = .notDetermined
        }
        // 健康步数（CoreMotion 计步器授权）
        switch CMPedometer.authorizationStatus() {
        case .authorized: s["health"] = .connected
        case .denied, .restricted: s["health"] = .denied
        case .notDetermined: s["health"] = .notDetermined
        @unknown default: s["health"] = .notDetermined
        }
        statuses = s
        // 软件：canOpenURL 检测（scheme 必须先在 Info.plist 声明，否则恒 false）
        var installed: [String: Bool] = [:]
        for app in apps {
            if let url = URL(string: "\(app.id)://") {
                installed[app.id] = UIApplication.shared.canOpenURL(url)
            }
        }
        installedApps = installed
    }

    private func mapAuth(_ status: PHAuthorizationStatus) -> Status {
        switch status {
        case .authorized, .limited: return .connected
        case .denied, .restricted: return .denied
        default: return .notDetermined
        }
    }

    private func mapAuth(_ status: AVAuthorizationStatus) -> Status {
        switch status {
        case .authorized: return .connected
        case .denied, .restricted: return .denied
        default: return .notDetermined
        }
    }

    private func mapAuth(_ status: UNAuthorizationStatus) -> Status {
        switch status {
        case .authorized, .provisional, .ephemeral: return .connected
        case .denied: return .denied
        default: return .notDetermined
        }
    }

    // MARK: 请求授权（用户点"连接"才走到这里）
    private func request(_ c: Connector) {
        switch c.id {
        case "browser":
            break   // 恒已连接，不会进到这
        case "calendar":
            EventKitManager.requestAccess { _ in refresh() }
        case "notifications":
            NotificationManager.requestAuthorization { _ in refresh() }
        case "location":
            locationManager.requestWhenInUseAuthorization()
            // 弹窗回调走 delegate，这里延迟刷一次状态（弹窗期间返回旧值也无妨）
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { refresh() }
        case "camera":
            AVCaptureDevice.requestAccess(for: .video) { _ in refresh() }
        case "photos":
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { _ in refresh() }
        case "microphone":
            AVAudioSession.sharedInstance().requestRecordPermission { _ in refresh() }
        case "health":
            // CMPedometer 没有独立的请求 API：首次查询会触发系统授权弹窗
            let pedometer = CMPedometer()
            let now = Date()
            pedometer.queryCMPedometerData(from: now.addingTimeInterval(-60), to: now) { _, _ in
                DispatchQueue.main.async { refresh() }
            }
        default:
            break
        }
    }
}
