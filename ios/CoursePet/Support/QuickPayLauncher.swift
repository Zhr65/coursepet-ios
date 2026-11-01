// MARK: - 快捷付款码唤起（锁屏小组件的中转终点）
//
// 为什么需要这一层：
// 锁屏圆形小组件用 `.widgetURL(...)` 发起跳转时，代码跑在**小组件扩展进程**里。
// 扩展进程调 openURL 会被系统收窄 —— 常见表现是目标 App 被拉到前台，但 URL 的
// path/query 被丢弃（落首页而不是付款码页）。用户看到的就是「点了微信付款码，
// 只是打开微信，还得自己点一次收付款」。
//
// 所以小组件不再直连第三方，改为发 coursepet://pay?app=… 回到主 App，
// 由主 App 进程（没有那层限制）用 UIApplication.open 去唤起，并按候选表逐个试
// —— 与 TransactionSections 里「快捷收付款」同一套候选值，避免两处漂移。
import Foundation
import UIKit

enum QuickPayLauncher {

    enum Target {
        case alipay
        case wechat
    }

    /// 候选 scheme 按序尝试，任一成功即停。
    ///
    /// ⚠️ 已知不确定项（写在这里避免以后误以为是 bug）：
    /// 微信**没有**公开可验证的「付款码页」deep link。`weixin://widget/pay` 来自社区
    /// 流传值，未经本机验证；微信若忽略该路由，行为等价于直接 `weixin://`（落首页）。
    /// 支付宝的 `appId=20000056` 是社区长期维护的付款码入口，命中率更高。
    /// 两者都无法在离线环境验证，真机上以实际落点为准。
    private static func candidates(for target: Target) -> [String] {
        switch target {
        case .wechat:
            return ["weixin://widget/pay", "weixin://"]
        case .alipay:
            // 先试各个前缀写法：部分版本只认 alipayqr:// 或 alipay://
            return ["alipays://platformapi/startapp?appId=20000056",
                    "alipayqr://platformapi/startapp?appId=20000056",
                    "alipay://platformapi/startapp?appId=20000056",
                    "alipays://"]
        }
    }

    /// 从主 App 进程唤起付款码页（逐个候选试，全失败静默）
    static func open(target: Target) {
        tryOpen(candidates(for: target), at: 0)
    }

    private static func tryOpen(_ list: [String], at index: Int) {
        guard index < list.count, let url = URL(string: list[index]) else { return }
        UIApplication.shared.open(url) { ok in
            // 失败才试下一个；成功就停（成功 = 目标 App 已被拉起）
            if !ok {
                DispatchQueue.main.async { tryOpen(list, at: index + 1) }
            }
        }
    }
}
