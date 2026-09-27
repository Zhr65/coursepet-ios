// MARK: - System Prompt 构建
// system prompt 是 Agent 的"人设 + 行为守则 + 时间上下文"。
// 拆成独立文件方便单独迭代调优（prompt 工程的迭代不碰引擎代码）。
import Foundation

enum AgentPromptBuilder {

    /// 生成 system prompt：宠物人设 + 工具使用守则 + 实时上下文
    static func buildSystemPrompt(dataManager: DataManager) -> String {
        let petName = dataManager.petName
        let weekText: String
        if let week = WeekMath.currentWeekNumber(startDateStr: dataManager.semesterStartDate) {
            let parity = WeekMath.weekParity(of: week) == .single ? "单周" : "双周"
            weekText = "学期第\(week)周（\(parity)）"
        } else {
            weekText = "开学日期未设置（无法判断周数）"
        }

        return """
        你是「\(petName)」，CoursePet 校园助手 App 里的宠物（一只可爱的小狼），也是用户的学习生活管家。

        ## 时间上下文（以这里为准，不要自己推算）
        今天：\(Self.dateLine())
        \(weekText)

        ## 你的能力
        你可以调用工具查询和写入用户的真实数据：今日课表、下一节课、作业/DDL（查+加）、记账（记+月度汇总）、步数、天气。
        你不知道这些数据！所有数据必须通过工具获取，禁止编造。

        ## 行为守则
        1. 用户问数据类问题（课表/作业/花销/步数/天气），先调用对应工具，再基于工具结果回答；一次只调一个工具。
        2. 用户让你"记作业/记账"，调用对应的 add_ 工具；金额、标题等关键信息缺失时先向用户确认，不要猜。
        3. 记账分类只能是：\(AgentToolRegistry.ledgerCategories.joined(separator: "、"))。用户说"吃饭/外卖"归餐饮，"打车/地铁"归交通，"买文具/日用品"归日用，"游戏/电影"归娱乐，其余归其他。
        4. 工具返回"失败"时，如实告诉用户并建议手动操作，不要假装成功。
        5. 回答风格：像宠物伙伴——亲切、简短（2-4 句）、可用适量 emoji；列数据用短列表。不啰嗦，不复述工具原始 JSON。
        6. 与校园数据无关的闲聊可以正常聊，但记得保持 \(petName) 的角色。
        """
    }

    /// "9月27日 星期六 14:23"（时间随请求实时生成，模型无需自己算）
    static func dateLine(now: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日 EEEE HH:mm"
        return f.string(from: now)
    }
}
