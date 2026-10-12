// MARK: - 银行/支付短信 → 账本条目解析器（纯本地正则，零网络零 token）
//
// 挂在 SMSEventRouter 的 .bankPay 分支上：短信里认出「消费」后，直接落成账本一笔。
//
// 为什么要单独一个解析器：银行短信里同时藏着好几种数字，最容易混淆的是这三个 ——
//   「交易额」「余额」「卡尾号」。
//   例：您尾号1234的储蓄卡10月12日19:30消费人民币25.50元，余额1,234.56元。
// 早期版本靠「支出动词 + 往后数 14 个字」取金额，结果被「尾号6666」坑了 ——
// 「微信支付」里的「支付」触发了锚点，锚点跨过「尾号」把卡号当成了消费额。
//
// 现在改成三步，每条都有明确的排除对象：
//   ① 先整段剔除「余额 / 额度 / 积分」这类干扰金额；
//   ② 只有**带「元」或带 ¥/￥ 符号**的数字才算金额候选 —— 卡尾号（尾号6666）、
//      日期（10月12日）、卡号都是裸数字，这条约束把它们天然挡在门外；
//   ③ 候选里优先取「前面紧邻支出动词」的那个，都不沾边就取第一个。
//
// 两个刻意的保守设计（宁可漏记，不可错记）：
//   · 渠道名里的「支付」二字（微信支付 / 京东支付…）不代表收支方向，判方向前先摘掉它，
//     否则任何一条「微信支付」短信都会被误判成支出；
//   · 找不到明确支出动词、只写了「转账」这种可进可出的词 → isExpense = false，只提醒不记账。
//
// 账本模型（LedgerEntry / monthTotal）只统计支出，所以收入类短信一律不落账。
import Foundation

enum BankPayParser {

    // MARK: - 解析结果
    struct Result {
        /// 交易金额（元，恒为正数）
        let amount: Double
        /// true = 消费/扣款/付款；false = 入账/退款/方向不明（由调用方决定是否落账）
        let isExpense: Bool
        /// 归入的六分类之一（餐饮/学习/交通/日用/娱乐/其他）
        let category: String
        /// 备注，如「美团·尾号1234」；全无信息时为空串
        let note: String
    }

    // MARK: - 主入口
    /// 解析一条银行/支付短信；找不到合法金额时返回 nil。
    static func parse(_ text: String) -> Result? {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }

        // 判方向与取金额都基于「剥掉渠道名里『支付』二字」的文本，
        // 但商户/渠道/卡号的提取仍用原文 —— 原文才认得全「微信支付」。
        let neutral = strippingChannelSuffix(body)
        let cleaned = strippingChannelSuffix(removingNoiseAmounts(body))

        guard let amount = extractTradeAmount(cleaned), amount > 0 else { return nil }

        let merchant = extractMerchant(body)
        let channel = channelWords.first { body.contains($0) }
        let tail = firstGroup(#"尾号\s*([0-9]{4})"#, in: body)

        return Result(
            amount: amount,
            isExpense: isExpense(neutral),
            category: category(forMerchant: merchant),
            note: buildNote(merchant: merchant, channel: channel, tail: tail))
    }

    // MARK: - 渠道名净化
    /// 「微信支付 / 京东支付 / 美团支付…」里的「支付」二字描述的是**渠道**，不是**收支方向**。
    /// 不摘掉它，「微信支付」这五个字会让任何一条短信都被判成支出。
    private static func strippingChannelSuffix(_ text: String) -> String {
        text.replacingOccurrences(
            of: #"(微信|京东|美团|抖音|华为|小米|苹果|银联)支付"#,
            with: "$1",
            options: .regularExpression)
    }

    // MARK: - ① 剔除干扰金额段
    /// 余额/额度/积分这些「不是交易额」的段落整段替换成空格。
    /// 用 `[^，,。;；]` 限定不跨句，防止把后面的交易额一起吞掉。
    private static let noiseAmountPatterns = [
        #"余额[^，,。;；]{0,24}?元"#,
        #"可用额度[^，,。;；]{0,24}?元"#,
        #"额度[^，,。;；]{0,24}?元"#,
        #"剩余[^，,。;；]{0,24}?元"#,
        #"可用[^，,。;；]{0,24}?元"#,
        #"积分[^，,。;；]{0,24}?分"#,
    ]

    private static func removingNoiseAmounts(_ text: String) -> String {
        var out = text
        for pattern in noiseAmountPatterns {
            out = out.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        return out
    }

    // MARK: - ② / ③ 取交易额
    /// 合法金额候选：数字 + 「元」
    private static let yuanAmountPattern = #"([0-9][0-9,]*(?:\.[0-9]{1,2})?)\s*元"#
    /// 合法金额候选：¥ / ￥ 前缀
    private static let symbolAmountPattern = #"[¥￥]\s*([0-9][0-9,]*(?:\.[0-9]{1,2})?)"#

    /// 收集文本里所有合法金额候选，按出现位置排序
    private static func amountCandidates(_ text: String) -> [(location: Int, value: Double)] {
        let ns = text as NSString
        var found: [(location: Int, value: Double)] = []
        for pattern in [yuanAmountPattern, symbolAmountPattern] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            regex.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
                guard let match, match.numberOfRanges > 1,
                      match.range(at: 1).location != NSNotFound else { return }
                let raw = ns.substring(with: match.range(at: 1)).replacingOccurrences(of: ",", with: "")
                guard let value = Double(raw) else { return }
                found.append((match.range.location, value))
            }
        }
        return found.sorted { $0.location < $1.location }
    }

    /// 优先取「前面 16 个字内出现支出动词」的候选；都不沾边就取第一个。
    private static func extractTradeAmount(_ cleaned: String) -> Double? {
        let candidates = amountCandidates(cleaned)
        guard !candidates.isEmpty else { return nil }
        let ns = cleaned as NSString
        for candidate in candidates {
            let start = max(0, candidate.location - 16)
            guard candidate.location > start else { continue }
            let prefix = ns.substring(with: NSRange(location: start, length: candidate.location - start))
            if expenseWords.contains(where: { prefix.contains($0) }) { return candidate.value }
        }
        return candidates.first?.value
    }

    // MARK: - 收支方向
    /// 明确表示支出的词
    private static let expenseWords = [
        "消费", "支出", "扣款", "付款", "购买", "已扣", "代扣", "转出", "缴纳", "缴费", "支付",
    ]
    /// 明确表示非支出的词（账本只记支出，命中这些一律不落账）
    private static let incomeWords = [
        "入账", "到账", "收入", "转入", "退款", "退回", "返现", "报销", "工资", "红包",
        "存入", "收到", "收款",
    ]

    /// 收入词优先拦截；否则才看支出词。
    /// 「转账」这类可进可出的词刻意不进任一词表 —— 方向存疑就不冒险记账。
    static func isExpense(_ text: String) -> Bool {
        if incomeWords.contains(where: { text.contains($0) }) { return false }
        return expenseWords.contains(where: { text.contains($0) })
    }

    // MARK: - 商户 / 渠道 → 分类
    /// 具体商户关键词 → 六分类。数组顺序即优先级（先匹配到的类别胜出）。
    private static let merchantMap: [(keywords: [String], category: String)] = [
        (["美团", "饿了么", "肯德基", "麦当劳", "星巴克", "瑞幸", "蜜雪", "食堂", "外卖",
          "餐饮", "饭店", "餐厅", "美食", "烧烤", "火锅", "奶茶", "咖啡", "面馆", "小吃"], "餐饮"),
        (["滴滴", "高德", "地铁", "公交", "铁路", "12306", "加油", "石油", "石化", "出租",
          "打车", "单车", "哈啰", "青桔", "车费", "停车", "高速", "机票", "航空"], "交通"),
        (["书店", "当当", "文具", "打印", "复印", "学费", "课程", "网课", "知网", "图书馆",
          "教育", "培训", "考试", "报名", "教材", "学习"], "学习"),
        (["超市", "永辉", "沃尔玛", "便利店", "盒马", "买菜", "淘宝", "天猫", "京东", "拼多多",
          "日用", "百货", "商场", "药店", "屈臣氏", "名创优品", "家电", "数码"], "日用"),
        (["电影", "影院", "游戏", "腾讯视频", "爱奇艺", "优酷", "哔哩哔哩", "网易云",
          "QQ音乐", "Steam", "网吧", "KTV", "娱乐", "会员", "演出", "门票"], "娱乐"),
    ]

    /// 支付渠道词：只用于备注，不参与分类（「支付宝」本身说明不了钱花在哪）
    private static let channelWords = [
        "支付宝", "微信支付", "财付通", "云闪付", "银联", "花呗", "京东支付", "美团支付", "抖音支付",
    ]

    /// 商户关键词 → 分类；认不出商户时归「其他」
    static func category(forMerchant merchant: String?) -> String {
        guard let merchant else { return "其他" }
        for (keywords, category) in merchantMap where keywords.contains(merchant) {
            return category
        }
        return "其他"
    }

    /// 在文本里找已知商户关键词，返回命中的那个词
    private static func extractMerchant(_ text: String) -> String? {
        for (keywords, _) in merchantMap {
            if let hit = keywords.first(where: { text.contains($0) }) { return hit }
        }
        // 再试「在XX消费 / 向XX付款」这类显式商户名；抓到的若是渠道名则不算商户（否则备注会重复）
        guard let explicit = firstGroup(#"在([^，,。;；\s¥￥]{2,14}?)(?:消费|付款|购买|就餐|结账)"#, in: text),
              !channelWords.contains(explicit) else { return nil }
        return explicit
    }

    // MARK: - 备注拼装
    private static func buildNote(merchant: String?, channel: String?, tail: String?) -> String {
        var parts: [String] = []
        if let merchant { parts.append(merchant) }
        // 商户与渠道同名时（如显式商户名恰好是「支付宝」）只留一次
        if let channel, channel != merchant { parts.append(channel) }
        if let tail { parts.append("尾号\(tail)") }
        return parts.joined(separator: "·")
    }

    // MARK: - 正则小工具
    /// 取第一个捕获组的字符串
    private static func firstGroup(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges > 1,
              match.range(at: 1).location != NSNotFound else { return nil }
        let value = ns.substring(with: match.range(at: 1))
                            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
