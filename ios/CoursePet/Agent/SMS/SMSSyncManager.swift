// MARK: - 短信监听 · 路径 A（灰色手段：CoreTelephony 私有 API，仅侧载自用）
// 原理：CTTelephonyCenter 是 CoreTelephony 内部管理"通信事件广播"的私有中心，
// 系统收到短信时向它广播 kCTMessageReceivedNotification，userInfo 里带完整短信对象。
// 该 API 无公开头文件：全部用 dlsym 动态取符号 + ObjC runtime 读字段，不参与链接，
// 编译期零痕迹；运行时探测失败（符号被删/沙箱拦截）时静默降级，回落快捷指令路径 B。
// 局限：只在 App 进程活着（前台 / 后台挂起）时收得到；App 被杀靠路径 B 兜底。
import Foundation
import Darwin

enum SMSSyncManager {

    // MARK: - 状态（设置页展示）
    enum PrivatePathStatus: Equatable {
        case off            // 开关没开
        case installed      // 监听已装上（能否真收到以实机为准，收不到就配路径 B）
        case unavailable    // 私有符号探测失败（本机不支持），自动回落路径 B
    }
    static private(set) var status: PrivatePathStatus = .off

    /// 最近一次收到短信的时刻（诊断用，设置页展示；持久化跨启动可看）：
    /// "installed"只代表监听装上了，不代表真能收到（iOS 大版本可能静默不投递）——
    /// 有这个时间戳，用户测一条就知道通道是死的还是压根没触发（自己发出的短信两条路都不读，属预期）。
    static private(set) var lastReceivedAt: Date? {
        get {
            let t = UserDefaults.standard.double(forKey: "sms.lastReceivedAt")
            return t > 0 ? Date(timeIntervalSince1970: t) : nil
        }
        set {
            UserDefaults.standard.set(newValue?.timeIntervalSince1970 ?? 0, forKey: "sms.lastReceivedAt")
        }
    }

    // MARK: - 私有符号声明（参数与 iOS 运行时头一致，手工 @convention(c)）
    private typealias CTGetDefaultFn = @convention(c) () -> UnsafeMutableRawPointer?
    private typealias CTCallback = @convention(c) (
        CFNotificationCenter?, UnsafeMutableRawPointer?, CFString?, UnsafeRawPointer?, CFDictionary?) -> Void
    private typealias CTAddObserverFn = @convention(c) (
        UnsafeMutableRawPointer, UnsafeMutableRawPointer?, CTCallback, CFString, UnsafeRawPointer?, Int) -> Void
    private typealias CTRemoveObserverFn = @convention(c) (
        UnsafeMutableRawPointer, UnsafeMutableRawPointer?, CTCallback, CFString, UnsafeRawPointer?) -> Void

    private static let notificationName = "kCTMessageReceivedNotification" as CFString
    /// 挂起也立即投递（CFNotificationSuspensionBehaviorDeliverImmediately = 4）
    private static let suspensionBehaviorDeliverImmediately = 4
    private static var installed = false

    // MARK: - 生命周期
    /// App 启动接线（CoursePetApp.init 调用；轻量无副作用，后台被 Intent 拉起也无害）
    static func bootstrap() {
        guard UserDefaults.standard.bool(forKey: "sms.enabled") else {
            status = .off
            return
        }
        install()
    }

    /// 设置页开关翻转时调用（装/卸监听 + 持久化）
    static func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: "sms.enabled")
        if on {
            install()
        } else {
            uninstall()
        }
    }

    // MARK: - 装/卸监听
    static func install() {
        guard !installed else { return }
        guard let handle = dlopen("/System/Library/Frameworks/CoreTelephony.framework/CoreTelephony", RTLD_LAZY),
              let getDefaultSym = dlsym(handle, "CTTelephonyCenterGetDefault"),
              let addObserverSym = dlsym(handle, "CTTelephonyCenterAddObserver") else {
            status = .unavailable
            return
        }
        let getDefault = unsafeBitCast(getDefaultSym, to: CTGetDefaultFn.self)
        guard let center = getDefault() else {
            status = .unavailable
            return
        }
        let addObserver = unsafeBitCast(addObserverSym, to: CTAddObserverFn.self)
        addObserver(center, nil, smsReceivedCallback, notificationName, nil,
                    suspensionBehaviorDeliverImmediately)
        installed = true
        status = .installed
    }

    static func uninstall() {
        guard installed else {
            status = .off
            return
        }
        installed = false
        status = .off
        guard let handle = dlopen("/System/Library/Frameworks/CoreTelephony.framework/CoreTelephony", RTLD_LAZY),
              let getDefaultSym = dlsym(handle, "CTTelephonyCenterGetDefault"),
              let removeSym = dlsym(handle, "CTTelephonyCenterRemoveObserver") else { return }
        let getDefault = unsafeBitCast(getDefaultSym, to: CTGetDefaultFn.self)
        guard let center = getDefault() else { return }
        let remove = unsafeBitCast(removeSym, to: CTRemoveObserverFn.self)
        remove(center, nil, smsReceivedCallback, notificationName, nil)
    }

    // MARK: - 系统回调（@convention(c)：不能捕获上下文，全部走静态成员）
    private static let smsReceivedCallback: CTCallback = { _, _, _, _, userInfo in
        guard let userInfo = userInfo else { return }
        let dict = unsafeBitCast(userInfo, to: NSDictionary.self)
        // 标准键 kCTMessageReceiverKeyMessages；不同系统版本键名可能变动，
        // 兜底取字典里第一个数组值（该通知 userInfo 里只有这一个数组）
        var messages = dict["kCTMessageReceiverKeyMessages"] as? [AnyObject]
        if messages == nil {
            for case let arr as [AnyObject] in dict.allValues {
                messages = arr
                break
            }
        }
        guard let messages else { return }

        for message in messages {
            // CTMessage 私有对象：只读 ObjC 对象字段（绝不能 perform 返回 int 的选择器，会崩）
            guard let senderObj = callObject(message, "sender") else { continue }
            let sender = extractPhone(senderObj)
            let text = callObject(message, "text").flatMap { $0 as? String }
                ?? callObject(message, "body").flatMap { $0 as? String }
                ?? callObject(message, "subject").flatMap { $0 as? String }
                ?? ""
            guard !text.isEmpty else { continue }
            Task { @MainActor in
                SMSSyncManager.lastReceivedAt = Date()
                SMSEventRouter.handle(sender: sender, text: text)
            }
        }
    }

    // MARK: - ObjC runtime 读取辅助
    /// 安全调用"返回对象"的选择器（responds 先探，避免 unrecognized selector 崩溃）
    private static func callObject(_ obj: AnyObject, _ selector: String) -> AnyObject? {
        let sel = NSSelectorFromString(selector)
        guard obj.responds(to: sel) else { return nil }
        return obj.perform(sel)?.takeUnretainedValue()
    }

    /// CTSIMSMEAddress → 手机号：属性名各版本不一，逐个尝试，最后从 description 抠数字
    private static func extractPhone(_ address: AnyObject) -> String {
        for name in ["phoneNumber", "formattedNumber", "value"] {
            if let phone = callObject(address, name).flatMap({ $0 as? String }), !phone.isEmpty {
                return phone
            }
        }
        let desc = callObject(address, "description").flatMap { $0 as? String } ?? ""
        if let regex = try? NSRegularExpression(pattern: #"\d{5,20}"#),
           let match = regex.firstMatch(in: desc, range: NSRange(location: 0, length: (desc as NSString).length)),
           match.numberOfRanges > 0 {
            return (desc as NSString).substring(with: match.range(at: 0))
        }
        return ""
    }
}
