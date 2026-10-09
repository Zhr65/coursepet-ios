// MARK: - 短信事件路由器（短信管家的大脑，端侧闭合）
// 两条入口汇到这里：
//   路径 A（灰色）：CoreTelephony 私有 API 监听（SMSSyncManager），App 活着就自动收
//   路径 B（正规）：快捷指令「收到信息」自动化 → ReceiveSMSIntent，App 被杀也能跑
// 四类动作（短信原文不过咱们服务器；Bark 镜像只发通知内容到 Bark 官方接口）：
//   快递      → 解析取件码/驿站/单号 → 自动入快递库 → 本地通知确认 + Bark 镜像
//   验证码    → 抠出验证码 → 自动复制剪贴板 → 本地通知（不 Bark：码不过第三方）
//   银行/支付 → 全文弹通知提醒 + Bark 镜像
//   学校/教务 → 截断入长期记忆（宠物下次聊天想得起来）+ 本地通知
// 其余短信静默忽略。同一条短信双路都送到时靠 60 秒指纹去重，只处理一次。
import Foundation
import UIKit
import UserNotifications

enum SMSEventRouter {

    // MARK: - 总开关（设置页「短信助手」；关掉后两条路径都静默）
    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: "sms.enabled")
    }

    // MARK: - 分类结果
    enum SMSEvent {
        case parcel(code: String, station: String?, tracking: String?)
        case otp(code: String)
        case bankPay
        case schoolNotice
        case ignore
    }

    // MARK: - 去重（路径 A/B 双保险：同内容 60 秒内只处理一次）
    private static var recentFingerprints: [String: Date] = [:]
    private static let dedupWindow: TimeInterval = 60

    // MARK: - 唯一入口（同步执行，主线程）
    /// 处理一条短信，返回处理摘要（快捷指令弹窗 / 设置页测试按钮展示用）
    @MainActor
    @discardableResult
    static func handle(sender: String, text: String) -> String {
        guard isEnabled else { return "短信自动处理已在 App 设置里关闭" }
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return "短信内容是空的，没处理" }

        // 去重：同一条短信两条路径都会送到，窗口内第二份直接丢弃
        let now = Date()
        recentFingerprints = recentFingerprints.filter { now.timeIntervalSince($0.value) < 300 }
        if let seen = recentFingerprints[body], now.timeIntervalSince(seen) < dedupWindow {
            return "（60 秒内已处理过同一条短信，跳过重复件）"
        }
        recentFingerprints[body] = now

        switch classify(sender: sender, text: body) {
        case let .parcel(code, station, tracking):
            let parcel = ParcelItem(
                code: code,
                station: station ?? "未识别驿站",
                note: "短信自动识别 · \(sender.isEmpty ? "未知号码" : sender)",
                trackingNumber: tracking)
            DataManager.shared.addParcel(parcel)
            let stationText = station ?? "未识别驿站"
            ActivityTimelineStore.record(icon: "shippingbox",
                                         title: "从短信记下了一个快递",
                                         detail: "取件码 \(code) · \(stationText)")
            notify(title: "📦 快递已记上", body: "取件码 \(code) · \(stationText)")
            BarkPush.send(title: "📦 快递已记上", body: "取件码 \(code) · \(stationText)", group: "CoursePet短信")
            return "已记上快递：取件码 \(code)，驿站 \(stationText)"

        case let .otp(code):
            UIPasteboard.general.string = code
            ActivityTimelineStore.record(icon: "keyboard",
                                         title: "从短信复制了一个验证码",
                                         detail: "\(displayName(sender)) · \(code)")
            notify(title: "验证码已复制：\(code)", body: "\(displayName(sender))：\(String(body.prefix(60)))")
            return "验证码 \(code) 已复制到剪贴板"

        case .bankPay:
            ActivityTimelineStore.record(icon: "creditcard",
                                         title: "收到一条银行/支付短信",
                                         detail: String(body.prefix(40)))
            let brief = String(body.prefix(120))
            notify(title: "💳 \(displayName(sender))", body: brief)
            BarkPush.send(title: "💳 银行/支付提醒", body: "\(displayName(sender))：\(brief)", group: "CoursePet短信")
            return "银行/支付提醒已转发"

        case .schoolNotice:
            AgentMemoryStore.remember(["收到学校通知（\(dateText())）：\(String(body.prefix(90)))"])
            ActivityTimelineStore.record(icon: "graduationcap",
                                         title: "把学校通知记进了记忆",
                                         detail: String(body.prefix(40)))
            notify(title: "🎓 学校通知已记进记忆", body: String(body.prefix(100)))
            return "学校通知已记进记忆，之后聊天我能想起来"

        case .ignore:
            return "普通短信，已静默忽略"
        }
    }

    // MARK: - 分类（纯本地正则，零网络零 token）
    static func classify(sender: String, text: String) -> SMSEvent {
        // 1) 验证码最优先：银行/学校短信也常夹验证码，先到先得；
        //    "取件码/提货码"不含这些关键词，不会误入本分支
        if let code = extractOTP(text) { return .otp(code: code) }
        // 2) 快递：ParcelSmsParser 认出取件码才算（解析失败绝不猜数据）
        if let parsed = ParcelSmsParser.parse(text) {
            return .parcel(code: parsed.code, station: parsed.station,
                           tracking: ParcelSmsParser.extractTrackingNumber(text))
        }
        // 3) 银行/支付：关键词 + 金额双条件（只有关键词不弹，避免营销短信刷屏）
        if bankKeywords.contains(where: text.contains), hasAmount(text) {
            return .bankPay
        }
        // 4) 学校/教务
        if schoolKeywords.contains(where: text.contains) {
            return .schoolNotice
        }
        return .ignore
    }

    // MARK: - 正则库
    /// 银行/支付关键词（命中其一 + 金额才算）
    private static let bankKeywords = [
        "银行", "储蓄卡", "信用卡", "余额", "扣款", "支出", "收入", "到账", "入账",
        "转账", "退款", "工资", "花呗", "支付宝", "微信支付", "财付通", "尾号",
    ]
    /// 学校/教务关键词（命中其一即入记忆）
    private static let schoolKeywords = [
        "教务处", "教务系统", "学院", "大学", "学校", "辅导员", "班主任",
        "选课", "调课", "停课", "补考", "考试", "成绩", "奖学金",
        "开学", "校医院", "校园卡", "图书馆", "讲座", "期末",
    ]
    /// 金额样式：¥123 或 123.45 元
    private static let amountRegex = try? NSRegularExpression(pattern: #"(?:[¥￥]\s*\d)|(\d[\d,]*(?:\.\d{1,2})?\s*元)"#)

    private static func hasAmount(_ text: String) -> Bool {
        guard let regex = amountRegex else { return false }
        let ns = text as NSString
        return regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) != nil
    }

    /// 验证码：关键词后 0~8 个非字母数字字符 + 4~8 位字母数字码
    /// （"回复TD退订"里的 TD 只有 2 位，够不到 4 位下限，不会误报）
    private static func extractOTP(_ text: String) -> String? {
        let pattern = #"(?:验证码|校验码|动态密码|动态码|确认码|verification code|code is)[^0-9A-Za-z]{0,8}([0-9A-Za-z]{4,8})"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges > 1 else { return nil }
        return ns.substring(with: match.range(at: 1))
    }

    // MARK: - 展示辅助
    /// 常见客服短号 → 人话名（银行短信标题更友好）
    private static func displayName(_ sender: String) -> String {
        switch sender {
        case "95588": return "工商银行"
        case "95533": return "建设银行"
        case "95599": return "农业银行"
        case "95566": return "中国银行"
        case "95555": return "招商银行"
        case "95580": return "邮储银行"
        case "95528": return "交通银行"
        case "95568": return "民生银行"
        case "10086": return "中国移动"
        case "10010": return "中国联通"
        case "10000": return "中国电信"
        case "12306": return "12306 铁路"
        default: return sender.isEmpty ? "短信" : sender
        }
    }

    private static func dateText(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = "M月d日 HH:mm"
        return f.string(from: date)
    }

    // MARK: - 本地通知（前台也弹：NotificationRouter 会 banner + 声音）
    private static func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "coursepet_sms_\(UUID().uuidString)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }

    // Bark 镜像逻辑已上移至共用组件 BarkPush（短信/事件提醒双处共用），
    // 隐私边界不变：只发"通知内容"到 Bark 官方接口 api.day.app，不经过咱们服务器。
}
