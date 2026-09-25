// MARK: - 数据持久化（App Group 共享 JSON + UserDefaults）
// 主 App 写，Widget 和 Live Activity 读；App Group ID: group.com.coursepet.app
import Foundation
import Combine

class DataManager: ObservableObject {
    static let shared = DataManager()

    /// 数据保存钩子（解耦设计）：主 App 启动时注入（用于重建本地课程提醒通知），
    /// Widget / Live Activity 扩展进程中保持 nil，不影响扩展运行。
    static var onStateSaved: (() -> Void)?

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
    @Published var petName: String = "小狼"
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
    /// 上课提醒开关（镜像 AppSettings.reminderEnabled）
    @Published var reminderEnabled: Bool = false
    /// 作业待办列表（独立持久化到 App Group 的 homeworks.json）
    @Published var homeworks: [HomeworkItem] = []
    /// 宠物等级（UserDefaults 独立持久化，每 30 EXP 升一级）
    @Published var petLevel: Int = 1
    /// 宠物当前经验（0 ~ expPerLevel-1，UserDefaults 独立持久化）
    @Published var petExp: Int = 0
    /// 每升一级所需经验值
    static let expPerLevel = 30

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
        // 加载作业待办列表（独立 JSON 文件）
        homeworks = loadHomeworks()
        // 加载宠物等级与经验（UserDefaults 独立持久化；缺键时 integer 返回 0，需兜底）
        petLevel = (userDefaults?.object(forKey: Keys.petLevel.rawValue) as? Int) ?? 1
        petExp = (userDefaults?.object(forKey: Keys.petExp.rawValue) as? Int) ?? 0
    }

    // MARK: - 应用状态
    /// 加载完整 AppState
    func loadState() -> AppState {
        if let json = loadJSON(), let state = try? JSONDecoder().decode(AppState.self, from: json) {
            return mergeDefaults(state)
        }
        // 磁盘读取或解码失败时回退到内存镜像，避免把已有课程等数据清空
        //（修复"添加课程后之前添加的会消失"：旧实现此处直接返回空 AppState）
        var fallback = AppState.default
        fallback.courses = courses
        return fallback
    }

    /// 保存完整 AppState
    /// - Parameter triggerHook: 是否触发数据保存钩子（打字等高频保存场景可传 false，避免频繁重建通知）
    func saveState(_ state: AppState, triggerHook: Bool = true) {
        do {
            let data = try JSONEncoder().encode(state)
            saveJSON(data)
            // 同步 UserDefaults 元数据（日期等）
            syncUserDefaults(from: state)
            // 同步 @Published 镜像属性，触发所有订阅视图刷新
            syncPublished(from: state)
            // 数据已落盘：通知主 App 重建本地课程提醒（钩子由主 App 注入，扩展中为 nil）
            if triggerHook {
                Self.onStateSaved?()
            }
        } catch {
            print("[DataManager] 保存失败：\(error)")
        }
    }

    /// 把当前 @Published 镜像状态整体写回磁盘（视图层改设置/宠物状态后调用）。
    /// 课程等数据始终以内存为准写回，避免"从磁盘重读旧数据再覆盖内存"导致的数据丢失。
    func savePublishedState(triggerHook: Bool = true) {
        var s = loadState()
        s.courses = courses
        s.semester.startDate = semesterStartDate
        s.pet.name = petName
        s.pet.mood = petMood
        s.pet.affection = petAffection
        s.pet.food = petFood
        s.pet.currentAction = petCurrentAction
        s.pet.bubbleText = petBubbleText
        s.settings.animSpeed = animSpeed
        s.settings.charId = charId
        s.settings.darkMode = darkMode
        s.settings.simLowBattery = simLowBattery
        s.settings.simCharging = simCharging
        s.settings.simMusic = simMusic
        s.settings.reminderEnabled = reminderEnabled
        saveState(s, triggerHook: triggerHook)
    }

    // MARK: - 课程增删
    /// 新增一门课程：追加进内存课程列表后整体写回磁盘（保证旧课程不被覆盖）
    func addCourse(_ course: Course) {
        var newCourse = course
        // 保证 id 唯一：与现有课程撞 id 时重新生成
        if courses.contains(where: { $0.id == newCourse.id }) {
            newCourse.id = UUID().uuidString
        }
        courses.append(newCourse)
        savePublishedState()
    }

    /// 批量导入课程（Excel 导入用）：全部追加进现有列表，不覆盖已有课程
    func appendCourses(_ newCourses: [Course]) {
        var list = newCourses
        let existingIds = Set(courses.map { $0.id })
        for index in list.indices where existingIds.contains(list[index].id) {
            list[index].id = UUID().uuidString
        }
        courses.append(contentsOf: list)
        savePublishedState()
    }

    /// 清空全部课程数据（保留宠物与设置），并通知界面刷新
    func clearCourses() {
        courses = []
        savePublishedState()
        // 显式触发一次钩子，确保课程清空后本地提醒一定被重建（refreshAll 幂等，重复调用无害）
        Self.onStateSaved?()
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
        reminderEnabled = state.settings.reminderEnabled
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
        case petLevel = "pet.level"
        case petExp = "pet.exp"
        case lastFocusDate = "focus.lastCompletedDate"
        case backgroundColorName = "settings.backgroundColorName"
        case reminderEnabled = "settings.reminderEnabled"
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

    // MARK: - 等级 / 经验
    /// 增加经验值；跨过升级线时自动升级并返回 true（调用方可据此弹升级 toast）
    @discardableResult
    func addEXP(_ amount: Int) -> Bool {
        guard amount > 0 else { return false }
        petExp += amount
        var leveled = false
        while petExp >= DataManager.expPerLevel {
            petExp -= DataManager.expPerLevel
            petLevel += 1
            leveled = true
        }
        persistLevelExp()
        return leveled
    }

    /// 持久化等级与经验到 UserDefaults
    private func persistLevelExp() {
        userDefaults?.set(petLevel, forKey: Keys.petLevel.rawValue)
        userDefaults?.set(petExp, forKey: Keys.petExp.rawValue)
    }

    /// 重置宠物等级与经验（清空全部数据时用）
    func resetLevelExp() {
        petLevel = 1
        petExp = 0
        persistLevelExp()
    }

    // MARK: - 每日专注记录（FeedView 每日任务与 FocusView 联动）
    /// 最近一次完成专注的日期；从未完成返回 nil
    func getLastFocusDate() -> Date? {
        let timestamp = userDefaults?.double(forKey: Keys.lastFocusDate.rawValue) ?? 0
        return timestamp > 0 ? Date(timeIntervalSince1970: timestamp) : nil
    }
    func setLastFocusDate(_ date: Date) {
        userDefaults?.set(date.timeIntervalSince1970, forKey: Keys.lastFocusDate.rawValue)
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

    // MARK: - 作业待办
    /// 未完成作业数量（供 tab 角标等使用）
    var pendingCount: Int {
        homeworks.filter { !$0.isDone }.count
    }

    /// 新增一条作业
    func addHomework(_ item: HomeworkItem) {
        homeworks.append(item)
        persistHomeworks()
    }

    /// 切换作业完成状态
    func toggleHomework(id: String) {
        guard let index = homeworks.firstIndex(where: { $0.id == id }) else { return }
        homeworks[index].isDone.toggle()
        // 记录完成时间（每日任务"完成 1 个作业"联动判断用），取消完成时清空
        homeworks[index].completedAt = homeworks[index].isDone ? Date() : nil
        persistHomeworks()
    }

    /// 删除一条作业
    func deleteHomework(id: String) {
        homeworks.removeAll { $0.id == id }
        persistHomeworks()
    }

    /// 把作业列表写入 App Group 容器的 homeworks.json
    private func persistHomeworks() {
        guard let dir = ensureContainerDirectory() else { return }
        guard let data = try? JSONEncoder().encode(homeworks) else { return }
        try? data.write(to: dir.appendingPathComponent("homeworks.json"))
    }

    /// 从 App Group 容器读取作业列表（文件不存在或损坏时返回空数组）
    private func loadHomeworks() -> [HomeworkItem] {
        guard let dir = containerDirectory else { return [] }
        let url = dir.appendingPathComponent("homeworks.json")
        guard let data = try? Data(contentsOf: url),
              let items = try? JSONDecoder().decode([HomeworkItem].self, from: data) else { return [] }
        return items
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
                bg: state.settings.bg,
                reminderEnabled: state.settings.reminderEnabled
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
        userDefaults?.set(state.settings.reminderEnabled, forKey: Keys.reminderEnabled.rawValue)
    }

    private func loadJSON() -> Data? {
        guard let dir = containerDirectory else { return nil }
        let url = dir.appendingPathComponent("courses.json")
        return try? Data(contentsOf: url)
    }

    /// 确保 App Group 容器内 Documents 子目录存在。
    /// 首次写入时容器内可能还没有该目录，Data.write 不会自动创建中间目录，
    /// 缺目录会导致所有保存静默失败（真机上表现为"添加课程后旧课程消失"）。
    private func ensureContainerDirectory() -> URL? {
        guard let dir = containerDirectory else { return nil }
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
        }
        return dir
    }

    private func saveJSON(_ data: Data) {
        guard let dir = ensureContainerDirectory() else { return }
        do {
            try data.write(to: dir.appendingPathComponent("courses.json"))
        } catch {
            print("[DataManager] courses.json 写入失败：\(error)")
        }
    }
}
