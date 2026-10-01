// MARK: - Agent 数据模型
// 定义"宠物管家"对话系统的核心数据结构。
// 三类消息与 OpenAI Function Calling 协议对齐：
//   user      → 用户说的话
//   assistant → 模型的回复；若模型决定调用工具，则附带 toolCalls（不说话只调工具）
//   tool      → 本地工具的执行结果，通过 toolCallId 关联回那次调用
import Foundation

// MARK: 一次工具调用请求（模型发起）
struct AgentToolCall {
    let id: String            // 调用唯一 id，回填结果时必须带上
    let functionName: String  // 要调用的工具名
    let argumentsJSON: String // 参数 JSON 字符串，如 "{\"title\":\"高数作业\"}"
}

// MARK: 引擎内部的消息表示（与 API 协议解耦）
struct AgentMessage {
    enum Role: String {
        case system = "system"
        case user = "user"
        case assistant = "assistant"
        case tool = "tool"
    }
    var role: Role
    var content: String
    /// assistant 消息可能附带的工具调用（模型决定"我要查一下"）
    var toolCalls: [AgentToolCall] = []
    /// tool 消息必须携带的调用 id（告诉模型这个结果对应哪次调用）
    var toolCallID: String? = nil
    /// 拍照多模态：user 消息附带的 base64 JPEG（仅发送当轮生效）
    var imageBase64: String? = nil

    static func user(_ text: String, image: String? = nil) -> AgentMessage {
        AgentMessage(role: .user, content: text, imageBase64: image)
    }
    static func assistant(_ text: String) -> AgentMessage {
        AgentMessage(role: .assistant, content: text)
    }
    static func toolResult(id: String, name: String, content: String) -> AgentMessage {
        AgentMessage(role: .tool, content: content, toolCallID: id)
    }
}

// MARK: 聊天界面的展示消息（UI 层专用，比引擎消息多一个"工具调用过程"标签）
struct ChatDisplayMessage: Identifiable {
    enum Kind {
        case user                       // 用户气泡
        case assistant                  // 宠物回复气泡
        case toolTrace(String)          // "🔍 查了一下课表…" 过程标签
        case error                      // 出错提示
        case card(AgentCard)            // 模式 11：可点击直达的结构化卡片
        case image(Data)                // 生图结果：宠物画好的图直接展示在聊天流（不入对话历史）
    }
    let id = UUID()
    let kind: Kind
    let text: String
    /// 拍照多模态：用户气泡里展示的图片（仅 user 消息携带）
    var imageData: Data? = nil
}

// MARK: 模式 11 结构化卡片（Agent 输出 = UI）
// Agent 回答不只吐文字，还能吐卡片 schema：作业卡/课表卡/账单卡直接在聊天里渲染，
// 点击走 coursepet:// 深链直达对应页面。数据形态与后端 tools.py _show_card 对齐。
struct AgentCard {
    enum CardType: String {
        case homework   // 作业/DDL 列表卡 → 事务页
        case schedule   // 今日课表卡 → 课表页
        case bill       // 本月账单卡 → 事务页（记账分段）
        case jump       // 外部服务跳转卡（订酒店/点外卖等）→ Safari 打开平台网页
    }
    struct Item {
        let primary: String     // 主标题：课程名/作业名/分类名
        let secondary: String   // 次要信息：时间/截止/金额
        let tertiary: String    // 补充信息：教室/关联课程/笔数
    }
    let cardType: CardType
    let title: String
    let items: [Item]
    let summary: String
    let platform: String    // jump 卡：平台标识（meituan/ctrip/taobao…），其余卡为空
    let query: String       // jump 卡：要搜/买的东西，其余卡为空

    /// 卡片点击后的直达路由（coursepet:// 已在主 App onOpenURL 注册）
    var deepLink: URL? {
        switch cardType {
        case .schedule: return URL(string: "coursepet://schedule")
        case .homework, .bill: return URL(string: "coursepet://todo")
        case .jump: return jumpURL
        }
    }

    /// jump 卡平台显示名（未知平台显示"网页"）
    var platformName: String { Self.platformNames[platform] ?? "网页" }

    /// jump 卡跳转链接：模型只给 platform+query，URL 一律由端侧白名单拼接（防注入/防幻觉链接）。
    /// 外卖/酒店类平台 H5 搜索参数不稳定 → 跳平台首页，要搜的内容展示在卡片上让用户自己搜。
    var jumpURL: URL? {
        let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        switch platform {
        case "taobao":   return URL(string: "https://s.taobao.com/search?q=\(q)")
        case "jd":       return URL(string: "https://search.jd.com/Search?keyword=\(q)")
        case "ctrip":    return URL(string: "https://hotels.ctrip.com/")
        case "meituan":  return URL(string: "https://h5.waimai.meituan.com/")
        case "eleme":    return URL(string: "https://h5.ele.me/")
        case "dianping": return URL(string: "https://www.dianping.com/")
        case "12306":    return URL(string: "https://www.12306.cn/index/")
        case "fliggy":   return URL(string: "https://www.fliggy.com/")
        case "netease":  return URL(string: "https://music.163.com/")
        case "bilibili": return URL(string: "https://search.bilibili.com/all?keyword=\(q)")
        case "amap":     return URL(string: "https://m.amap.com/")
        default:         return URL(string: "https://www.bing.com/search?q=\(platform)%20\(q)")
        }
    }

    /// jump 卡私有 scheme 直跳（只配把握大的平台）：先试 scheme 直拉 App，
    /// 没装/失败时由调用方回落 jumpURL（https）——装了 App 的真机上 https 走
    /// Universal Links 本身也会优先拉 App，scheme 只是提高命中率。
    var schemeURL: URL? {
        switch platform {
        case "taobao":   return URL(string: "taobao://")
        case "jd":       return URL(string: "openapp.jdmobile://")
        case "ctrip":    return URL(string: "ctrip://")
        case "meituan":  return URL(string: "meituanwaimai://")
        case "eleme":    return URL(string: "eleme://")
        case "dianping": return URL(string: "dianping://")
        case "fliggy":   return URL(string: "fliggy://")
        case "netease":  return URL(string: "orpheus://")
        case "bilibili": return URL(string: "bilibili://")
        case "amap":     return URL(string: "iosamap://")
        default:         return nil
        }
    }

    static let platformNames = [
        "meituan": "美团外卖", "eleme": "饿了么", "ctrip": "携程", "dianping": "大众点评",
        "taobao": "淘宝", "jd": "京东", "12306": "12306", "fliggy": "飞猪",
        "netease": "网易云音乐", "bilibili": "哔哩哔哩", "amap": "高德地图",
    ]

    var symbolName: String {
        switch cardType {
        case .homework: return "checklist"
        case .schedule: return "calendar"
        case .bill:     return "yensign.circle"
        case .jump:     return "safari"
        }
    }

    /// 解析 show_card 的参数 / 服务端 kind="card" 消息体；类型或条目非法时返回 nil
    static func parse(_ jsonText: String) -> AgentCard? {
        guard let data = jsonText.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let typeRaw = obj["cardType"] as? String,
              let cardType = CardType(rawValue: typeRaw),
              let rawItems = obj["items"] as? [[String: Any]]
        else { return nil }
        let items: [Item] = rawItems.compactMap { raw in
            guard let primary = (raw["primary"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !primary.isEmpty
            else { return nil }
            return Item(primary: String(primary.prefix(60)),
                        secondary: raw["secondary"] as? String ?? "",
                        tertiary: raw["tertiary"] as? String ?? "")
        }
        guard !items.isEmpty else { return nil }
        let rawTitle = (obj["title"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return AgentCard(
            cardType: cardType,
            title: rawTitle.isEmpty ? defaultTitle(cardType) : String(rawTitle.prefix(30)),
            items: Array(items.prefix(12)),
            summary: (obj["summary"] as? String) ?? "",
            platform: (obj["platform"] as? String) ?? "",
            query: (obj["query"] as? String) ?? ""
        )
    }

    private static func defaultTitle(_ type: CardType) -> String {
        switch type {
        case .homework: return "未完成作业"
        case .schedule: return "今日课表"
        case .bill:     return "本月账单"
        case .jump:     return "去完成"
        }
    }
}

// MARK: Agent 配置（设置页可改，Key 存 Keychain）
struct AgentConfig {
    /// OpenAI 兼容端点，默认 DeepSeek（国内直连、便宜、Function Calling 稳定）
    var baseURL: String
    /// API Key（不落 UserDefaults，只进 Keychain）
    var apiKey: String
    /// 模型名，如 deepseek-chat
    var model: String
    /// 图像理解模型（场景路由）：带图消息自动切换到此模型；空=跟随主模型。
    /// 同一家服务商共用接口地址与 Key（如主 glm-4.7-flash + 视觉 glm-5.3-flash）
    var visionModel: String = ""

    static let `default` = AgentConfig(
        baseURL: "https://api.deepseek.com/v1",
        apiKey: "",
        model: "deepseek-chat"
    )

    var isConfigured: Bool { !apiKey.isEmpty && !baseURL.isEmpty && !model.isEmpty }
}
