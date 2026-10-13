// MARK: - App 私有 scheme 探测器
//
// 为什么需要这个文件：
// 给「一扫」补跳转规则时，头部 App（淘宝/京东/美团…）的 scheme 有社区清单可查，
// 但国内中小 App 的 scheme 属于「三无」——
//   ① 社区清单不收录（WengYuehTing、csh1314 两个仓库逐条查过，没有知到/超星）；
//   ② 官网没配 Universal Link（zhihuishu.com 主域 + 10 个子域的
//      /.well-known/apple-app-site-association 全部 404 或不可达，
//      所以 open(https://…) 必然落 Safari，这条路是死的）；
//   ③ 应用商店页面、下载引导页都不含 scheme 字样。
// 一个 App 的 CFBundleURLSchemes 只在它自己的 Info.plist 里，而沙箱不允许读别的
// App 的 bundle。所以**唯一可靠的办法是在真机上问系统**：这个 scheme 现在有没有
// App 认领。这就是本文件干的事 —— 把「猜一个写进代码里等构建」换成「在手机上
// 当场测出来」。本来打算从 IPA 里读 Info.plist，但 iTunes 备份从 iOS 9 起就不含
// App 二进制，第三方解密 IPA 站又要么要 UDID 要么直接 403，成本远高于自测。
//
// 两种手段，各有取舍，界面上都给了：
//
//   快速探测（canOpenURL）
//     优点：零打扰，一次把整张表测完，结果精确。
//     代价：scheme 必须先声明在 Info.plist 的 LSApplicationQueriesSchemes 里，
//           没声明的一律返回 false —— 注意这是「白名单没声明」而不是「没装」，
//           两者在这个 API 上完全无法区分。系统对该数组有 50 条上限，
//           本条规则已用掉 43 条，所以表不能无限长。
//
//   深度探测（open）
//     优点：不受白名单限制，任何 scheme 都能试，不存在 50 条上限。
//     代价：open 成功 = 对方 App 真的被拉到前台，测一个就跳走一次。
//           所以策略是「命中即停」—— 第一个被接走的候选就是答案，立刻收工。
//     这条路兜住了「快速探测全 false，但其实是白名单没声明」的假阴性。
import Foundation
import UIKit

/// 一个待探测的 scheme
struct SchemeProbeItem: Identifiable, Hashable {
    var id: String { scheme }
    /// 纯 scheme，不含 "://"
    let scheme: String
    /// 这个候选取自哪种命名习惯 —— 看结果时能知道「哪类猜法命中了」
    let origin: String
    var url: URL { URL(string: "\(scheme)://")! }
}

/// 单条探测结果
struct SchemeProbeResult: Identifiable, Hashable {
    var id: String { item.scheme }
    let item: SchemeProbeItem
    /// true = 系统里有 App 认领了这个 scheme
    let available: Bool
}

enum SchemeProbe {

    // MARK: 候选表

    /// 知到（智慧树）候选。
    ///
    /// 命名的三种常见习惯都覆盖了 —— 国内 App 起 scheme 基本不出这三类：
    ///   ① 品牌拼音（zhihuishu）/ 英文品牌名（wisdomtree）
    ///   ② Bundle ID 或其片段（com.able-elec.WisdomTreeZs 的后半截）
    ///   ③ 公司简称（上海卓越睿新数码科技的英文主体是 ABLE DIGITAL & TECH，
    ///      所以 able / ableelec 也要试）
    ///
    /// 已知事实（用于对照，不是猜测）：
    ///   iOS Bundle ID   com.able-elec.WisdomTreeZs
    ///   Android 包名    com.able.wisdomtree
    ///   开发者           上海卓越睿新数码科技股份有限公司 / SHANGHAI ABLE DIGITAL & TECH
    ///   App Store ID    1255358463
    ///
    /// 表里每一条都必须在 Info.plist 的 LSApplicationQueriesSchemes 里有同名字符串，
    /// 否则快速探测对它恒返回 false（见文件头说明）。
    static let zhidaoCandidates: [SchemeProbeItem] = [
        SchemeProbeItem(scheme: "zhihuishu",        origin: "品牌拼音"),
        SchemeProbeItem(scheme: "wisdomtree",       origin: "英文品牌名"),
        SchemeProbeItem(scheme: "zhs",              origin: "品牌拼音缩写"),
        SchemeProbeItem(scheme: "zhidao",           origin: "App 中文名拼音"),
        SchemeProbeItem(scheme: "com.able.wisdomtree",        origin: "Android 包名"),
        SchemeProbeItem(scheme: "com.able-elec.WisdomTreeZs", origin: "iOS Bundle ID"),
        SchemeProbeItem(scheme: "able",             origin: "公司英文简称"),
        SchemeProbeItem(scheme: "ableelec",         origin: "公司名缩写连写"),
        SchemeProbeItem(scheme: "able-elec",        origin: "公司名连写"),
        SchemeProbeItem(scheme: "wisdomtreezs",     origin: "Bundle ID 后半截"),
        SchemeProbeItem(scheme: "zhihuishuapp",     origin: "品牌 + app"),
        SchemeProbeItem(scheme: "zhihuishustudy",   origin: "品牌 + study"),
        SchemeProbeItem(scheme: "zdedu",            origin: "知到拼音首字母 + edu"),
        SchemeProbeItem(scheme: "ableapp",          origin: "公司简称 + app"),
        SchemeProbeItem(scheme: "zhshu",            origin: "智慧树拼音缩写"),
    ]

    // MARK: 探测

    /// 快速探测：纯查表，不产生任何跳转。
    /// 同步返回 —— canOpenURL 是本地查询，不会卡。
    static func quick(_ items: [SchemeProbeItem]) -> [SchemeProbeResult] {
        items.map { SchemeProbeResult(item: $0,
                                      available: UIApplication.shared.canOpenURL($0.url)) }
    }

    /// 深度探测：逐个 open，命中即停。
    ///
    /// 为什么命中即停而不是测完：open 成功意味着对方 App 已经被拉到前台，
    /// 本 App 随即进后台 —— 继续往下测要靠系统给的那点后台执行时间，不可靠，
    /// 而且此时用户已经在别的 App 里，再弹别的 App 只会更乱。
    /// 第一个被接走的候选就是答案，足够了。
    ///
    /// 为什么每次失败后要等 0.35s：连续 open 一串不存在的 scheme 会被系统节流，
    /// 间隔太小后面的候选可能还没轮到就被吞掉，出现假阴性。
    static func deep(_ items: [SchemeProbeItem],
                     index: Int = 0,
                     acc: [SchemeProbeResult] = [],
                     completion: @escaping ([SchemeProbeResult], SchemeProbeItem?) -> Void) {
        guard index < items.count else {
            DispatchQueue.main.async { completion(acc, nil) }
            return
        }
        let item = items[index]
        UIApplication.shared.open(item.url) { ok in
            var next = acc
            next.append(SchemeProbeResult(item: item, available: ok))
            if ok {
                DispatchQueue.main.async { completion(next, item) }
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    deep(items, index: index + 1, acc: next, completion: completion)
                }
            }
        }
    }

    // MARK: 报告

    /// 拼一段可复制的纯文本报告 —— 本机没有 Xcode、拿不到控制台，
    /// 用户把这段粘回来就是最直接的排障信息。
    static func report(quick: [SchemeProbeResult],
                       deep: [SchemeProbeResult],
                       hit: SchemeProbeItem?) -> String {
        var lines: [String] = []
        lines.append("CoursePet scheme 探测报告")
        lines.append("系统: \(UIDevice.current.systemName) \(UIDevice.current.systemVersion)")
        lines.append("机型: \(UIDevice.current.model)")
        lines.append("")

        if !quick.isEmpty {
            lines.append("[快速探测 canOpenURL]")
            for r in quick {
                lines.append("  \(r.available ? "命中" : "未中")  \(r.item.scheme)://  (\(r.item.origin))")
            }
            let n = quick.filter(\.available).count
            lines.append("  小计: \(n)/\(quick.count) 命中")
            lines.append("")
        }

        if !deep.isEmpty {
            lines.append("[深度探测 open]")
            for r in deep {
                lines.append("  \(r.available ? "被接走" : "无响应")  \(r.item.scheme)://")
            }
            lines.append("")
        }

        if let hit {
            lines.append("结论: 知到的 scheme 是 \(hit.scheme)://  (取名习惯: \(hit.origin))")
        } else if !deep.isEmpty || !quick.isEmpty {
            lines.append("结论: 本轮候选全部未命中")
        }
        return lines.joined(separator: "\n")
    }
}
