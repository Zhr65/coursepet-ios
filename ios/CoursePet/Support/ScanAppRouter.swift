// MARK: - 扫码落点解析（域名 → 目标 App / App 内页面）
//
// 「一扫」这类工具真正难的不是 open(url)，而是 open 之前那一步：判断这个码属于谁。
//
// 原实现把 http(s) 一律归为「网页」，直接 open 交给系统，注释里写着
// 「微信/支付宝/淘宝域名的通用链接 open 即直达 App」—— 这个前提是错的：
// Universal Link 要求目标 App 自己声明 applinks:<域名> 并托管 AASA 文件，
// 国内 App 基本没为业务域名做这件事，于是 open(https://…) 必然落 Safari。
// 表现出来就是「扫什么都进浏览器」。
//
// 正确做法是维护一张「域名 → 该平台 App 私有 scheme」表，先试 scheme 唤起，
// 失败（没装 / scheme 被改版废弃）再退到 https。这与仓库既有的
// TransactionSections.swift（PickupApp / PaymentApp「按顺序试、任一成功即停」）
// 是同一套模式，只是当时只补了「去取件 / 查账单」两个入口，扫码链路漏了。
//
// 两个 iOS 侧硬约束，写在这里避免以后踩：
//  ① canOpenURL 只回答「scheme 是否声明在 LSApplicationQueriesSchemes 里」，
//     没声明的一律 false；本文件因此不走 canOpenURL 门禁，直接用 open 的
//     回调判断成败 —— open 不受该白名单限制。
//  ② open 的自定义 scheme 回调 true 只代表「已交给某个 App」，
//     不代表对方处理成功。因此候选表里精确路由排在通用首页之前。
import Foundation
import UIKit

/// 扫码落点
enum ScanDestination: Equatable {
    /// 拉起第三方 App
    case app(ScanAppTarget)
    /// 落到本 App 内的某个页面（走 coursepet:// 深链，复用 ContentView.handleDeepLink）
    case inApp(ScanInAppPage)
}

/// 一个第三方 App 的唤起方案
struct ScanAppTarget: Equatable {
    let name: String
    /// 按顺序尝试，任一唤起成功即停
    let candidates: [URL]
    /// 全部失败时的网页回落（没装 App 时至少能看到内容）
    let web: URL?
    /// 拉起 App 后要不要继续把「扫一扫」也递过去（两段式跳转）。
    ///
    /// 为什么需要这一步：车身码（共享单车/充电宝）与收付款码的归宿是
    /// **对方 App 的扫一扫界面** —— 那一串 bikeId / 订单号只在对方自己扫出来的
    /// 上下文里有效，外部 URL 递进去一律不认（防伪造开锁、资金安全的硬边界）。
    /// 所以能做的只是「少一步」：把用户从「App 首页 → 自己找扫一扫入口」
    /// 变成「App 直接开在扫一扫」，**省掉的是找入口，不是再扫一次**。
    var scanBridge: [URL] = []
}

/// 本 App 内页面：host 必须是 ContentView.handleDeepLink 已支持的取值
enum ScanInAppPage: Equatable {
    case todo       // 事务页（作业列表 / 课程平台绑定入口）

    var deepLink: URL { URL(string: "coursepet://todo")! }
    var name: String { "事务页" }
}

/// 跳转结果，供 UI 决定提示文案
enum ScanOpenResult: Equatable {
    case openedApp(String)   // 成功拉起某 App
    case openedWeb           // 落到了网页
    case handedInApp(String) // 已交给本 App 内的页面
    case failed              // 全链路失败
}

/// 万能兜底扫一扫：微信 / 支付宝。
///
/// 这是「一扫」这类工具真正的底牌 —— 国内几乎任何码（小程序码、单车码、充电宝码、
/// 商家码、收款码）微信或支付宝都扫得动，所以不必为每个小众品牌单独去挖 scheme。
/// 结果面板把它做成一个次要按钮，主按钮判不出归属或失败时用它兜。
enum ScanFallbackScanner: String, CaseIterable, Identifiable {
    case wechat
    case alipay

    var id: String { rawValue }

    var name: String {
        switch self {
        case .wechat: return "微信"
        case .alipay: return "支付宝"
        }
    }

    /// 各家的「扫一扫」入口。微信的 weixin://scanqrcode 与支付宝的 saId=10000007
    /// 是社区长期维护、多份清单互相印证的稳定值（见 WengYuehTing/url-scheme-collection）。
    /// 支付宝另备 alipayqr:// 前缀 —— 部分版本只认它。
    var candidates: [URL] {
        switch self {
        case .wechat:
            return [URL(string: "weixin://scanqrcode")!]
        case .alipay:
            return [URL(string: "alipays://platformapi/startapp?saId=10000007")!,
                    URL(string: "alipayqr://platformapi/startapp?saId=10000007")!,
                    URL(string: "alipay://platformapi/startapp?saId=10000007")!]
        }
    }
}

enum ScanAppRouter {

    // MARK: 主入口

    /// 按解析结果打开 url；completion 一定在主线程回调一次。
    static func open(_ url: URL, completion: @escaping (ScanOpenResult) -> Void) {
        guard let destination = destination(for: url) else {
            // 没进表：维持原行为交给系统 —— 声明了 Universal Link 的走 App，
            // 其余落 Safari。不硬塞一张表是为了避免误判把用户带进不相干的 App。
            systemOpen(url) { ok in completion(ok ? .openedWeb : .failed) }
            return
        }
        switch destination {
        case .inApp(let page):
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .coursepetOpenNotificationRoute,
                    object: nil,
                    userInfo: ["url": page.deepLink])
                completion(.handedInApp(page.name))
            }
        case .app(let target):
            tryOpen(target.candidates, at: 0, target: target,
                    web: target.web ?? url, completion: completion)
        }
    }

    /// 万能兜底：把「微信 / 支付宝扫一扫」交给系统打开。
    /// 逐个候选按序试，任一成功即停（各家 scheme 有版本差异，支付宝尤其要多备几个前缀）。
    /// 全失败回调 false —— 说明连这两家都没装，属于极端情况。
    static func openFallbackScanner(_ scanner: ScanFallbackScanner,
                                    completion: @escaping (Bool) -> Void) {
        tryFallback(scanner.candidates, at: 0, completion: completion)
    }

    private static func tryFallback(_ candidates: [URL],
                                    at index: Int,
                                    completion: @escaping (Bool) -> Void) {
        guard index < candidates.count else {
            DispatchQueue.main.async { completion(false) }
            return
        }
        UIApplication.shared.open(candidates[index]) { ok in
            if ok {
                DispatchQueue.main.async { completion(true) }
            } else {
                tryFallback(candidates, at: index + 1, completion: completion)
            }
        }
    }

    /// 纯查表，供 UI 预告「这个码会去哪儿」，不产生副作用
    static func destination(for url: URL) -> ScanDestination? {
        guard let host = normalizedHost(of: url) else { return nil }
        for rule in rules where rule.suffixes.contains(where: { matches(host: host, suffix: $0) }) {
            return rule.build(url)
        }
        return nil
    }

    /// UI 用：把落点转成按钮文案（"用 淘宝 打开" / "在 事务页 打开"）
    static func actionTitle(for url: URL) -> String? {
        switch destination(for: url) {
        case .app(let target):   return "用 \(target.name) 打开"
        case .inApp(let page):   return "在\(page.name)中打开"
        case nil:                return nil
        }
    }

    /// UI 用：这个码是不是「要进对方扫一扫才能完成」的类型（车身码 / 收付款码）。
    /// 是的话结果面板会额外露出微信/支付宝扫一扫兜底按钮 ——
    /// 因为对方 App 改版导致 bridge 失效时，用户得有后路。
    static func needsScanBridge(for url: URL) -> Bool {
        guard case .app(let target) = destination(for: url) else { return false }
        return !target.scanBridge.isEmpty
    }

    // MARK: 匹配

    private static func normalizedHost(of url: URL) -> String? {
        guard let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        if host.hasPrefix("www.") { return String(host.dropFirst(4)) }
        return host
    }

    /// host == suffix 或 host 以 .suffix 结尾才算命中。
    /// 不能直接 hasSuffix(suffix)：那样 notjd.com 会命中 jd.com。
    private static func matches(host: String, suffix: String) -> Bool {
        host == suffix || host.hasSuffix("." + suffix)
    }

    // MARK: 候选表

    private struct Rule {
        let suffixes: [String]
        let build: (URL) -> ScanDestination
    }

    /// 顺序敏感：更精确的域名写前面
    private static let rules: [Rule] = [
        // ── 校园平台：本 App 已内置对应模块（AgentZhsClient / ChaoxingClient），
        // 这两家没有可公开验证的私有 scheme，硬编码一个猜的只会失败回落 Safari，
        // 不如落到本 App 内已经能用的绑定/作业页 —— 这也正是「跳转到对应的页面」。
        Rule(suffixes: ["zhihuishu.com"]) { _ in .inApp(.todo) },
        Rule(suffixes: ["chaoxing.com", "xuexitong.com"]) { _ in .inApp(.todo) },

        // ── 电商
        Rule(suffixes: ["taobao.com", "tmall.com", "tb.cn"]) { taobao($0) },
        Rule(suffixes: ["jd.com", "3.cn"]) { .app(ScanAppTarget(
            name: "京东",
            candidates: [URL(string: "openapp.jdmobile://")!],
            web: $0)) },
        Rule(suffixes: ["pinduoduo.com", "yangkeduo.com", "pinduoduo.net"]) { .app(ScanAppTarget(
            name: "拼多多",
            candidates: [URL(string: "pinduoduo://")!],
            web: $0)) },

        // ── 生活服务
        Rule(suffixes: ["meituan.com", "meituan.net"]) { .app(ScanAppTarget(
            name: "美团",
            candidates: [URL(string: "imeituan://")!, URL(string: "meituanwaimai://")!],
            web: $0)) },
        Rule(suffixes: ["ele.me", "eleme.cn"]) { .app(ScanAppTarget(
            name: "饿了么",
            candidates: [URL(string: "eleme://")!],
            web: $0)) },
        Rule(suffixes: ["dianping.com"]) { .app(ScanAppTarget(
            name: "大众点评",
            candidates: [URL(string: "dianping://")!],
            web: $0)) },
        Rule(suffixes: ["amap.com", "gaode.com", "autonavi.com"]) { .app(ScanAppTarget(
            name: "高德地图",
            candidates: [URL(string: "iosamap://")!],
            web: $0)) },

        // ── 出行
        Rule(suffixes: ["ctrip.com", "trip.com"]) { .app(ScanAppTarget(
            name: "携程",
            candidates: [URL(string: "ctrip://")!],
            web: $0)) },
        Rule(suffixes: ["fliggy.com", "alitrip.com"]) { .app(ScanAppTarget(
            name: "飞猪",
            candidates: [URL(string: "fliggy://")!],
            web: $0)) },

        // ── 支付 / 社交
        Rule(suffixes: ["weixin.qq.com", "weixin.com", "mp.weixin.qq.com"]) { .app(ScanAppTarget(
            name: "微信",
            candidates: [URL(string: "weixin://")!],
            web: $0)) },
        Rule(suffixes: ["alipay.com", "alipayobjects.com",
                        "antgroup.com", "antfin.com", "mybank.cn",
                        "aliyun.com"]) { .app(ScanAppTarget(
            name: "支付宝",
            // aliyun.com 域名下的二维码其实是支付宝收银台链接(2026-10-13 反馈),
            // 命中时跳转 alipays:// 让支付宝 App 接管(走支付宝自己的扫一扫)
            // 不要再开网页 —— 支付宝网页支付反而不识别 aliyun 域的收银台
            candidates: [URL(string: "alipays://")!, URL(string: "alipay://")!],
            web: $0)) },

        // ── 内容
        Rule(suffixes: ["bilibili.com", "b23.tv"]) { .app(ScanAppTarget(
            name: "哔哩哔哩",
            candidates: [URL(string: "bilibili://")!],
            web: $0)) },
        Rule(suffixes: ["music.163.com"]) { .app(ScanAppTarget(
            name: "网易云音乐",
            candidates: [URL(string: "orpheus://")!],
            web: $0)) },

        // ── 共享出行（车身码：两段式，拉起对方扫一扫）
        // 单车/助力车的车身码只有对方 App 自己扫才认，外部 URL 递不进去（防伪造开锁）。
        // 能省的是「找入口」这一步，见 ScanAppTarget.scanBridge 的说明。
        // 顺序敏感：hello.com 要排在美团前面（美团也有 hello 相关子域时的保护）
        Rule(suffixes: ["hello.com", "hellobike.com"]) { .app(ScanAppTarget(
            name: "哈啰",
            candidates: [URL(string: "hellobike://")!],
            web: $0,
            // 这一条是 V2EX 真人验证过的（不只是清单抄录）：2022 年悬赏帖里
            // h404bi 给出 hellobike://hellobike.com/scan_qr 并当场验证成功
            scanBridge: [URL(string: "hellobike://hellobike.com/scan_qr")!])) },
        Rule(suffixes: ["bike.meituan.com", "meituanbike.com"]) { .app(ScanAppTarget(
            name: "美团单车",
            candidates: [URL(string: "imeituan://")!],
            web: $0,
            scanBridge: [URL(string: "imeituan://www.meituan.com/scanQRCode?openAR=1")!])) },
        Rule(suffixes: ["qingju.com", "qingjubike.com"]) { .app(ScanAppTarget(
            name: "青桔单车",
            candidates: [URL(string: "blackhorse://")!, URL(string: "diditaxi://")!],
            web: $0,
            scanBridge: [URL(string: "blackhorse://qrscan")!])) },

        // ── 共享充电宝（街电 / 怪兽：只查到主 scheme，扫一扫入口无公开验证值，
        //    故不硬编 scanBridge —— 失败会落微信扫码兜底，比猜一个不存在的 path 强）
        Rule(suffixes: ["jiedianyuan.com", "jiedian.com"]) { .app(ScanAppTarget(
            name: "街电",
            candidates: [URL(string: "jiedianapp://")!],
            web: $0)) },
        Rule(suffixes: ["enmonster.com", "monsterenergy.cn"]) { .app(ScanAppTarget(
            name: "怪兽充电",
            candidates: [URL(string: "monsterapp://")!],
            web: $0)) },
    ]

    /// 淘宝需要把落地页塞进 Deeplink 的 h5Url 参数才能在 App 内打开指定页，
    /// 参数格式照抄 TransactionSections.swift:228（阿里妈妈「流量宝 Deeplink」），
    /// 失败再退到首页级 scheme。
    private static func taobao(_ url: URL) -> ScanDestination {
        var candidates: [URL] = []
        let h5 = url.absoluteString
            .addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? url.absoluteString
        if let wrapped = URL(string: "tbopen://m.taobao.com/tbopen/index.html?&action=ali.open.nav&module=h5&source=coursepet&h5Url=\(h5)&backURL=coursepet%3A%2F%2F") {
            candidates.append(wrapped)
        }
        candidates.append(URL(string: "taobao://")!)
        candidates.append(URL(string: "tbopen://")!)
        return .app(ScanAppTarget(name: "淘宝", candidates: candidates, web: url))
    }

    // MARK: 打开

    /// 逐个尝试候选 scheme，全失败才落网页。
    /// 成功拉起 App 后，若有 scanBridge（车身码/收付款码这类要进对方扫一扫的），
    /// 紧接着把 bridge 也 open 一次 —— 对方 App 已在栈顶，这一步只是把它的
    /// 扫一扫页面从内部唤起，用户不会看到二次跳转。
    private static func tryOpen(_ candidates: [URL],
                                at index: Int,
                                target: ScanAppTarget,
                                web: URL,
                                completion: @escaping (ScanOpenResult) -> Void) {
        guard index < candidates.count else {
            systemOpen(web) { ok in completion(ok ? .openedWeb : .failed) }
            return
        }
        UIApplication.shared.open(candidates[index]) { ok in
            if ok {
                handOffScanBridge(target.scanBridge) { completion(.openedApp(target.name)) }
            } else {
                tryOpen(candidates, at: index + 1, target: target, web: web, completion: completion)
            }
        }
    }

    /// 交棒：把扫一扫入口递进刚拉起的 App。
    /// 延迟 0.45s 是必要的 —— App 冷启动时它的 URL scheme handler 还没注册完，
    /// 立刻 open 会被系统丢弃、静默无效。0.45s 是冷启动与热启动都能覆盖的经验值。
    /// bridge 失败**不算整体失败**：用户已经被带到目标 App 首页了，
    /// 只是需要自己点一下扫一扫；比回落网页好得多。
    private static func handOffScanBridge(_ bridge: [URL],
                                          completion: @escaping () -> Void) {
        guard !bridge.isEmpty else {
            DispatchQueue.main.async { completion() }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            tryBridge(bridge, at: 0, completion: completion)
        }
    }

    private static func tryBridge(_ bridge: [URL],
                                  at index: Int,
                                  completion: @escaping () -> Void) {
        guard index < bridge.count else {
            DispatchQueue.main.async { completion() }
            return
        }
        UIApplication.shared.open(bridge[index]) { ok in
            if ok {
                DispatchQueue.main.async { completion() }
            } else {
                tryBridge(bridge, at: index + 1, completion: completion)
            }
        }
    }

    private static func systemOpen(_ url: URL, completion: @escaping (Bool) -> Void) {
        UIApplication.shared.open(url) { ok in
            DispatchQueue.main.async { completion(ok) }
        }
    }
}
