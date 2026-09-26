// MARK: - Siri 快捷指令（AppIntents，iOS 16+）
// 三个能力：查今日课程 / 记待办 / 快速记账。
// 主 App 进程内直接读 DataManager（Shared 单例），无需网络与后端。
// 首次调用时系统会自动引导授权 Siri，用户也可在 设置 → Siri 与搜索 中管理。
import AppIntents

// MARK: - 查今日课程
struct TodayScheduleIntent: AppIntent {
    static let title: LocalizedStringResource = "今天有什么课"
    static let description = IntentDescription("播报今天的课程安排，含时间与教室")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let dm = DataManager.shared
        guard !dm.semesterStartDate.isEmpty, !dm.courses.isEmpty else {
            return .result(dialog: "还没有课表数据，打开 CoursePet 导入课表吧")
        }
        // 学期周数
        guard let week = WeekMath.currentWeekNumber(startDateStr: dm.semesterStartDate, now: Date()) else {
            return .result(dialog: "还没开学，好好享受假期！")
        }
        // 今天是周几（Calendar weekday 1=周日 → 课程模型 1=周一…7=周日）
        let weekday = Calendar.current.component(.weekday, from: Date())
        let day = weekday == 1 ? 7 : weekday - 1
        // 该周今天的课程，按开始时间排序
        let todayCourses = ScheduleHelpers.courses(forWeek: week, courses: dm.courses)
            .filter { $0.dayOfWeek == day }
            .sorted { $0.startTime < $1.startTime }

        if todayCourses.isEmpty {
            return .result(dialog: "今天没有课，好好休息！")
        }
        let dayNames = ["一", "二", "三", "四", "五", "六", "日"]
        let lines = todayCourses.map { "周\(dayNames[day - 1]) \($0.startTime) 《\($0.name)》\($0.location.isEmpty ? "" : " \($0.location)")" }
        let dialog = IntentDialog("今天 \(todayCourses.count) 节课：\n" + lines.joined(separator: "\n"))
        return .result(dialog: dialog)
    }
}

// MARK: - 记待办
struct AddTodoIntent: AppIntent {
    static let title: LocalizedStringResource = "记待办"
    static let description = IntentDescription("快速添加一条待办事项")

    // Siri 参数（说"用 CoursePet 记待办 写实验报告"）
    @Parameter(title: "事项内容")
    var task: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let content = task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else {
            return .result(dialog: "要记什么事呀？告诉我具体内容")
        }
        DataManager.shared.addHomework(HomeworkItem(title: content))
        return .result(dialog: "已添加待办「\(content)」")
    }
}

// MARK: - 快速记账
struct QuickLedgerIntent: AppIntent {
    static let title: LocalizedStringResource = "记一笔花销"
    static let description = IntentDescription("快速记一笔支出，自动归入「其他」分类，可稍后在事务页修改")

    @Parameter(title: "金额（元）")
    var amount: Double

    @Parameter(title: "备注", default: "")
    var note: String

    static var parameterSummary: some ParameterSummary {
        Summary("花了 \(\.$amount) 元，\(\.$note)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard amount > 0, amount < 1_000_000 else {
            return .result(dialog: "金额要在 0 到一百万之间哦")
        }
        let cleaned = note.trimmingCharacters(in: .whitespacesAndNewlines)
        DataManager.shared.addLedgerEntry(LedgerEntry(
            amount: amount,
            category: "其他",
            note: cleaned.isEmpty ? nil : cleaned
        ))
        return .result(dialog: "已记下：\(String(format: "%.2f", amount)) 元")
    }
}

// MARK: - App 快捷指令注册（锁屏/Siri 建议直接可用，无需手动配置）
struct CoursePetAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: TodayScheduleIntent(),
            phrases: [
                "用\(.applicationName)查课",
                "用\(.applicationName)看看今天的课",
            ],
            shortTitle: "今日课程",
            systemImageName: "calendar"
        )
        AppShortcut(
            intent: AddTodoIntent(),
            phrases: [
                "用\(.applicationName)记待办",
                "用\(.applicationName)添加待办",
            ],
            shortTitle: "记待办",
            systemImageName: "checklist"
        )
        AppShortcut(
            intent: QuickLedgerIntent(),
            phrases: [
                "用\(.applicationName)记账",
                "用\(.applicationName)记一笔花销",
            ],
            shortTitle: "快速记账",
            systemImageName: "yensign.circle"
        )
    }
}
