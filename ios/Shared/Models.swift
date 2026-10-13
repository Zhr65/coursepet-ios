// MARK: - 数据模型（与 Web 原型保持一致）
// 对应 prototype/js/store.js 和 prototype/js/schedule.js 的结构

import Foundation

// MARK: - 课程模型
// Hashable：Timetable 声明了 Hashable，其 courses 数组要求元素可哈希（2026-10-14 补）
struct Course: Identifiable, Codable, Sendable, Hashable {
    var id: String
    var name: String
    var teacher: String
    var location: String
    var dayOfWeek: Int        // 1=周一 … 7=周日
    var startTime: String     // "HH:mm"
    var endTime: String
    var startWeek: Int
    var endWeek: Int
    var weekParity: WeekParity
    var color: String         // 十六进制颜色字符串，如 "#FFD1C4"

    init(
        id: String = UUID().uuidString,
        name: String,
        teacher: String = "",
        location: String = "",
        dayOfWeek: Int,
        startTime: String,
        endTime: String,
        startWeek: Int = 1,
        endWeek: Int = 20,
        weekParity: WeekParity = .both,
        color: String? = nil
    ) {
        self.id = id
        self.name = name
        self.teacher = teacher
        self.location = location
        self.dayOfWeek = dayOfWeek
        self.startTime = startTime
        self.endTime = endTime
        self.startWeek = startWeek
        self.endWeek = endWeek
        self.weekParity = weekParity
        self.color = color ?? CourseColorPalette.color(forDay: dayOfWeek)
    }
}

enum WeekParity: String, Codable, CaseIterable {
    case single, double, both
}

struct CourseColorPalette {
    // 与 Web 原型 COURSE_COLORS 一致
    static let colors = [
        "#FFD1C4", "#C4E3FF", "#C9F2D0", "#FFF3BF",
        "#E5D4FF", "#FFE0B8", "#CBEFE7"
    ]
    static func color(forDay day: Int) -> String {
        return colors[(day - 1) % colors.count]
    }
}

// MARK: - 学期信息
struct SemesterInfo: Codable, Sendable {
    var startDate: String   // "YYYY-MM-DD"

    init(startDate: String = "") {
        self.startDate = startDate
    }
}

// MARK: - Timetable（多课程表，2026-10-13 起）
// 一张 Timetable = 一个学期（一或多门课 + 该学期开学日期）。
// DataManager 用 `timetables` + `activeTimetableId` 持有全部表；
// `dm.courses` / `dm.semesterStartDate` 保持为活动课表的镜像，
// 这样全库 30+ 个课程消费点不用改一行代码。
// 旧 JSON 缺 `timetables` 字段时用已有 courses + semester.startDate
// 迁移成一张名为"当前学期"的默认课表，userVisible id 与启动日期挂钩。
struct Timetable: Codable, Identifiable, Hashable {
    var id: String                // UUID 字符串，新建时生成
    var name: String              // 学期名（如"2025 秋季"），可重命名
    var startDate: String         // 该学期开学日期 "YYYY-MM-DD"，决定 WeekMath 的第几周
    var courses: [Course] = []    // 该学期的全部课程块
    var createdAt: Date = Date()  // 建表时间，用于列表排序与显示

    init(id: String = UUID().uuidString,
         name: String,
         startDate: String,
         courses: [Course] = [],
         createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.startDate = startDate
        self.courses = courses
        self.createdAt = createdAt
    }
}

// MARK: - 宠物状态
struct PetState: Codable, Sendable {
    var name: String = "小狼"
    var mood: Int = 70          // 0-100
    var affection: Int = 0      // 0-100
    var food: Int = 5
    var currentAction: String = "idle"   // 当前播放的动作（给 Widget 用）
    var bubbleText: String = ""
}

// MARK: - 背景设置
struct BackgroundSetting: Codable, Sendable {
    var mode: BGMode = .default
    var color: String = "#FFD9C9"
    var gradient: String = "sunset"
    var image: String = ""       // base64 图片数据（可选，体积大时慎用）
    var opacity: Double = 0.6

    enum BGMode: String, Codable, CaseIterable {
        case `default`, color, gradient, image
    }
}

// MARK: - 应用设置
struct AppSettings: Codable, Sendable {
    var animSpeed: AnimSpeed = .mid
    var charId: String = "char1"
    var darkMode: Bool = false
    var simLowBattery: Bool = false
    var simCharging: Bool = false
    var simMusic: Bool = false
    var bg: BackgroundSetting = BackgroundSetting()
    /// 上课提醒开关（提前 15 分钟本地通知，仅主 App 消费）
    var reminderEnabled: Bool = false

    enum AnimSpeed: String, Codable, CaseIterable {
        case slow, mid, fast
    }

    private enum CodingKeys: String, CodingKey {
        case animSpeed, charId, darkMode, simLowBattery, simCharging, simMusic, bg, reminderEnabled
    }
}

extension AppSettings {
    // 自定义解码：旧版本 JSON 中没有 reminderEnabled 字段时用默认值兜底，
    // 避免合成解码因 keyNotFound 整体失败导致课程等数据被重置丢失。
    // 注意：放在 extension 中定义，不抑制 struct 的 memberwise init 合成。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        animSpeed = try c.decodeIfPresent(AnimSpeed.self, forKey: .animSpeed) ?? .mid
        charId = try c.decodeIfPresent(String.self, forKey: .charId) ?? "char1"
        darkMode = try c.decodeIfPresent(Bool.self, forKey: .darkMode) ?? false
        simLowBattery = try c.decodeIfPresent(Bool.self, forKey: .simLowBattery) ?? false
        simCharging = try c.decodeIfPresent(Bool.self, forKey: .simCharging) ?? false
        simMusic = try c.decodeIfPresent(Bool.self, forKey: .simMusic) ?? false
        bg = try c.decodeIfPresent(BackgroundSetting.self, forKey: .bg) ?? BackgroundSetting()
        reminderEnabled = try c.decodeIfPresent(Bool.self, forKey: .reminderEnabled) ?? false
    }
}

// MARK: - 作业待办
struct HomeworkItem: Codable, Identifiable {
    var id: String = UUID().uuidString
    var title: String
    /// 关联课程名（可选，nil 表示不关联）
    var courseName: String? = nil
    /// 到期日期（可选）
    var dueDate: Date? = nil
    var isDone: Bool = false
    /// 完成时间（每日任务"完成 1 个作业"联动判断用；旧数据无此字段，解码时兜底 nil）
    var completedAt: Date? = nil
    var createdAt: Date = Date()
    /// 同步来源（nil = 手动添加；"chaoxing" = 学习通平台同步）
    var source: String? = nil
    /// 平台侧唯一键（同步 upsert/删除的幂等键，如 "chaoxing:49156357"；手动添加为 nil）
    var sourceKey: String? = nil
}

// MARK: - 快递取件
struct ParcelItem: Codable, Identifiable {
    var id: String = UUID().uuidString
    /// 取件码（必填）
    var code: String
    /// 驿站名 / 位置
    var station: String
    /// 备注（如"顺丰，是书"）
    var note: String? = nil
    /// 快递单号（可空：短信里有才存，用于实时物流查询）
    var trackingNumber: String? = nil
    /// 入库时间
    var createdAt: Date = Date()
    /// 取件时间（nil = 未取）
    var pickedAt: Date? = nil
}

// MARK: - 记账条目
struct LedgerEntry: Codable, Identifiable {
    var id: String = UUID().uuidString
    /// 金额（元，支出为正数记录）
    var amount: Double
    /// 分类（餐饮/学习/交通/日用/娱乐/其他）
    var category: String
    /// 备注（可选）
    var note: String? = nil
    /// 消费时间
    var date: Date = Date()
    /// 记录来源：nil = 手动/语音录入；"短信" = 银行/支付短信自动记；"截屏" = 截图识别
    /// （Optional 才能安全解码旧版本存下的 ledger.json —— 缺字段时自动为 nil）
    var source: String? = nil
}

/// 记账分类（固定 6 类，简单不纠结）
enum LedgerCategory {
    static let all = ["餐饮", "学习", "交通", "日用", "娱乐", "其他"]
    static let icons = ["餐饮": "fork.knife", "学习": "book", "交通": "bus", "日用": "cart", "娱乐": "gamecontroller", "其他": "ellipsis.circle"]
}

// MARK: - 完整应用状态
struct AppState: Codable, Sendable {
    var version: Int = 1
    var semester: SemesterInfo = SemesterInfo()
    var courses: [Course] = []
    var pet: PetState = PetState()
    var settings: AppSettings = AppSettings()

    // 多课程表（2026-10-13 起）—— 老 JSON 缺这两个字段时解码失败风险已用
    // Codable 合成容错：缺字段默认为空数组与 nil，再由 DataManager 做迁移。
    var timetables: [Timetable] = []
    var activeTimetableId: String? = nil
}

// MARK: - 默认值
extension AppState {
    static let `default` = AppState()
}
