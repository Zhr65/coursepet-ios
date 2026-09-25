// MARK: - 数据持久化（App Group 共享 JSON + UserDefaults）
// 主 App 写，Widget 和 Live Activity 读；App Group ID: group.com.coursepet.app
import Foundation

class DataManager {
    static let shared = DataManager()

    // 必须与 Xcode 项目中设置的 App Group 名称一致
    static let appGroupID = "group.com.coursepet.app"

    // UserDefaults suite 名称
    private var userDefaults: UserDefaults?
    // App Group 容器目录（存放 courses.json）
    private var containerDirectory: URL?

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
        } catch {
            print("[DataManager] 保存失败：\(error)")
        }
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

    func isDarkMode() -> Bool {
        return userDefaults?.bool(forKey: Keys.darkMode.rawValue) ?? false
    }
    func setDarkMode(_ on: Bool) {
        userDefaults?.set(on, forKey: Keys.darkMode.rawValue)
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
            settings: AppSettings(
                animSpeed: state.settings.animSpeed,
                charId: state.settings.charId,
                darkMode: state.settings.darkMode
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
