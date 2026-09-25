// MARK: - 数据持久化（App Group 共享 JSON + UserDefaults）
// 主 App 写，Widget 和 Live Activity 读；App Group ID: group.com.coursepet.app
import Foundation
import Combine

class DataManager: ObservableObject {
    static let shared = DataManager()

    // 必须与 Xcode 项目中设置的 App Group 名称一致
    static let appGroupID = "group.com.coursepet.app"

    // UserDefaults suite 名称
    private var userDefaults: UserDefaults?
    // App Group 容器目录（存放 courses.json）
    private var containerDirectory: URL?

    // MARK: - 可观察状态（@Published 镜像属性）
    // 磁盘仍是唯一数据源（JSON + UserDefaults），这些属性在 saveState 时同步，
    // 赋值会自动触发 objectWillChange，让所有订阅的 SwiftUI 视图立即刷新。
    @Published var courses: [Course] = []
    @Published var semesterStartDate: String = ""
    @Published var petName: String = "小火人"
    @Published var petMood: Int = 70
    @Published var petAffection: Int = 0
    @Published var petFood: Int = 5
    @Published var petCurrentAction: String = "idle"
    @Published var petBubbleText: String = ""
    @Published var animSpeed: AppSettings.AnimSpeed = .mid
    @Published var charId: String = "char1"
    @Published var darkMode: Bool = false
    @Published var simLowBattery: Bool = false
    @Published var simCharging: Bool = false
    @Published var simMusic: Bool = false
    /// 背景主题名称（仅存 UserDefaults，见 getBackgroundColorName/setBackgroundColorName）
    @Published var backgroundColorName: String = "默认灰"

    /// 初始化：验证 App Group 是否可用
    private init() {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: DataManager.appGroupID) else {
            print("[DataManager] ⚠️ App Group '\(DataManager.appGroupID)' 不可用，请检查 Entitlements 配置。")
            containerDirectory = nil
            return
        }
        containerDirectory = container.appendingPathComponent("Documents")
        userDefaults = UserDefaults(suiteName: DataManager.appGroupID)
        print("[DataManager] ✅ App Group 已连接，容器路径：\(container.path)")
        // 冷启动时从磁盘加载 @Published 镜像属性，避免首帧显示默认值
        syncPublished(from: loadState())
    }

    // MARK: - 应用状态
    /// 加载完整 AppState
    func loadState() -> AppState {
        if let json = loadJSON(), let state = try? JSONDecoder().decode(AppState.self, from: json) {
            return mergeDefaults(state)
        }
        return AppState.default
    }

    /// 保存完整 AppState
    func saveState(_ state: AppState) {
        do {
            let data = try JSONEncoder().encode(state)
            saveJSON(data)
            // 同步 UserDefaults 元数据（日期等）
            syncUserDefaults(from: state)
            // 同步 @Published 镜像属性，触发所有订阅视图刷新
            syncPublished(from: state)
        } catch {
            print("[DataManager] 保存失败：\(error)")
        }
    }

    /// 清空全部课程数据（保留宠物与设置），并通知界面刷新
    func clearCourses() {
        var state = loadState()
        state.courses = []
        saveState(state)
    }

    // MARK: - @Published 镜像同步
    /// 把 AppState 同步到 @Published 镜像属性（赋值自动触发 objectWillChange）
    private func syncPublished(from state: AppState) {
        courses = state.courses
        semesterStartDate = state.semester.startDate
        petName = state.pet.name
        petMood = state.pet.mood
        petAffection = state.pet.affection
        petFood = state.pet.food
        petCurrentAction = state.pet.currentAction
        petBubbleText = state.pet.bubbleText
        animSpeed = state.settings.animSpeed
        charId = state.settings.charId
        darkMode = state.settings.darkMode
        simLowBattery = state.settings.simLowBattery
        simCharging = state.settings.simCharging
        simMusic = state.settings.simMusic
        backgroundColorName = getBackgroundColorName()
    }

    // MARK: - UserDefaults 键
    enum Keys: String {
        case semesterStartDate = "semester.startDate"
        case petMood = "pet.mood"
        case petAffection = "pet.affection"
        case petFood = "pet.food"
        case petName = "pet.name"
        case animSpeed = "settings.animSpeed"
        case charId = "settings.charId"
        case darkMode = "settings.darkMode"
        case simLowBattery = "settings.simLowBattery"
        case simCharging = "settings.simCharging"
        case simMusic = "settings.simMusic"
        case currentAction = "pet.currentAction"
        case bubbleText = "pet.bubbleText"
        case lastCheckInTimestamp = "pet.lastCheckInTimestamp"
        case checkInStreak = "pet.checkInStreak"
        case backgroundColorName = "settings.backgroundColorName"
    }

    // MARK: - 便捷读写
    func getSemesterStartDate() -> String? {
        return userDefaults?.string(forKey: Keys.semesterStartDate.rawValue)
    }
    func setSemesterStartDate(_ date: String?) {
        userDefaults?.set(date, forKey: Keys.semesterStartDate.rawValue)
    }

    func getPetMood() -> Int {
        return userDefaults?.integer(forKey: Keys.petMood.rawValue) ?? 70
    }
    func setPetMood(_ mood: Int) {
        userDefaults?.set(mood, forKey: Keys.petMood.rawValue)
    }

    func getPetFood() -> Int {
        return userDefaults?.integer(forKey: Keys.petFood.rawValue) ?? 5
    }
    func setPetFood(_ food: Int) {
        userDefaults?.set(food, forKey: Keys.petFood.rawValue)
    }

    func getAnimSpeed() -> AppSettings.AnimSpeed {
        guard let raw = userDefaults?.string(forKey: Keys.animSpeed.rawValue) else { return .mid }
        return AppSettings.AnimSpeed(rawValue: raw) ?? .mid
    }
    func setAnimSpeed(_ speed: AppSettings.AnimSpeed) {
        userDefaults?.set(speed.rawValue, forKey: Keys.animSpeed.rawValue)
    }

    func getCharId() -> String {
        return userDefaults?.string(forKey: Keys.charId.rawValue) ?? "char1"
    }
    func setCharId(_ id: String) {
        userDefaults?.set(id, forKey: Keys.charId.rawValue)
    }

    /// 是否深色模式（读取 @Published 属性，变化时自动刷新依赖它的视图）
    func isDarkMode() -> Bool {
        return darkMode
    }
    func setDarkMode(_ on: Bool) {
        darkMode = on
        userDefaults?.set(on, forKey: Keys.darkMode.rawValue)
    }

    // MARK: - 每日签到（连续天数跨天判断由调用方用 Calendar.isDate 完成）
    /// 最近一次签到的日期；从未签到返回 nil
    func getLastCheckInDate() -> Date? {
        let timestamp = userDefaults?.double(forKey: Keys.lastCheckInTimestamp.rawValue) ?? 0
        return timestamp > 0 ? Date(timeIntervalSince1970: timestamp) : nil
    }
    func setLastCheckInDate(_ date: Date) {
        userDefaults?.set(date.timeIntervalSince1970, forKey: Keys.lastCheckInTimestamp.rawValue)
    }
    /// 已连续签到天数
    func getCheckInStreak() -> Int {
        return userDefaults?.integer(forKey: Keys.checkInStreak.rawValue) ?? 0
    }
    func setCheckInStreak(_ days: Int) {
        userDefaults?.set(days, forKey: Keys.checkInStreak.rawValue)
    }

    // MARK: - 背景主题
    /// 当前背景主题名称（预设："默认灰"、"晨雾蓝"、"樱花粉"、"薄荷绿"、"暖阳橙"）
    func getBackgroundColorName() -> String {
        return userDefaults?.string(forKey: Keys.backgroundColorName.rawValue) ?? "默认灰"
    }
    func setBackgroundColorName(_ name: String) {
        backgroundColorName = name
        userDefaults?.set(name, forKey: Keys.backgroundColorName.rawValue)
    }

    /// 读取当前宠物动作（由状态机或手动操作更新，供 Widget/Activity 读取）
    func getCurrentAction() -> String {
        return userDefaults?.string(forKey: Keys.currentAction.rawValue) ?? "idle"
    }
    func setCurrentAction(_ action: String) {
        userDefaults?.set(action, forKey: Keys.currentAction.rawValue)
    }

    /// 读取当前宠物气泡
    func getBubbleText() -> String {
        return userDefaults?.string(forKey: Keys.bubbleText.rawValue) ?? ""
    }
    func setBubbleText(_ text: String) {
        userDefaults?.set(text, forKey: Keys.bubbleText.rawValue)
    }

    // MARK: - 私有方法
    private func mergeDefaults(_ state: AppState) -> AppState {
        return AppState(
            semester: SemesterInfo(startDate: state.semester.startDate),
            courses: state.courses,
            pet: PetState(
                name: state.pet.name,
                mood: state.pet.mood,
                affection: state.pet.affection,
                food: state.pet.food,
                currentAction: state.pet.currentAction,
                bubbleText: state.pet.bubbleText
            ),
            // 注意：模拟开关等设置项必须原样带回，否则保存后重新读取会丢失
            settings: AppSettings(
                animSpeed: state.settings.animSpeed,
                charId: state.settings.charId,
                darkMode: state.settings.darkMode,
                simLowBattery: state.settings.simLowBattery,
                simCharging: state.settings.simCharging,
                simMusic: state.settings.simMusic,
                bg: state.settings.bg
            )
        )
    }

    private func syncUserDefaults(from state: AppState) {
        userDefaults?.set(state.semester.startDate, forKey: Keys.semesterStartDate.rawValue)
        userDefaults?.set(state.pet.mood, forKey: Keys.petMood.rawValue)
        userDefaults?.set(state.pet.food, forKey: Keys.petFood.rawValue)
        userDefaults?.set(state.pet.name, forKey: Keys.petName.rawValue)
        userDefaults?.set(state.settings.animSpeed.rawValue, forKey: Keys.animSpeed.rawValue)
        userDefaults?.set(state.settings.charId, forKey: Keys.charId.rawValue)
        userDefaults?.set(state.settings.darkMode, forKey: Keys.darkMode.rawValue)
        userDefaults?.set(state.settings.simLowBattery, forKey: Keys.simLowBattery.rawValue)
        userDefaults?.set(state.settings.simCharging, forKey: Keys.simCharging.rawValue)
        userDefaults?.set(state.settings.simMusic, forKey: Keys.simMusic.rawValue)
        userDefaults?.set(state.pet.currentAction, forKey: Keys.currentAction.rawValue)
        userDefaults?.set(state.pet.bubbleText, forKey: Keys.bubbleText.rawValue)
    }

    private func loadJSON() -> Data? {
        guard let dir = containerDirectory else { return nil }
        let url = dir.appendingPathComponent("courses.json")
        return try? Data(contentsOf: url)
    }

    private func saveJSON(_ data: Data) {
        guard let dir = containerDirectory else { return }
        try? data.write(to: dir.appendingPathComponent("courses.json"))
    }
}
