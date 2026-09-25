// MARK: - 数据模型（与 Web 原型保持一致）
// 对应 prototype/js/store.js 和 prototype/js/schedule.js 的结构

import Foundation

// MARK: - 课程模型
struct Course: Identifiable, Codable, Sendable {
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
        color: String = CourseColorPalette.color(forDay: dayOfWeek)
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
        self.color = color
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

// MARK: - 宠物状态
struct PetState: Codable, Sendable {
    var name: String = "小火人"
    var mood: Int = 70          // 0-100
    var affection: Int = 0      // 0-100
    var food: Int = 5
    var currentAction: String = "idle"   // 当前播放的动作（给 Widget 用）
    var bubbleText: String = ""

    init() {}
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

    enum AnimSpeed: String, Codable, CaseIterable {
        case slow, mid, fast
    }
}

// MARK: - 完整应用状态
struct AppState: Codable, Sendable {
    var version: Int = 1
    var semester: SemesterInfo = SemesterInfo()
    var courses: [Course] = []
    var pet: PetState = PetState()
    var settings: AppSettings = AppSettings()
}

// MARK: - 默认值
extension AppState {
    static let `default` = AppState()
}
