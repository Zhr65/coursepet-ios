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
    /// 允许"空课表覆盖磁盘"的开关：只有用户显式清空课程时才打开。
    /// 未打开时空覆盖会被 saveState 拦下——防解码失败的空内存状态抹掉磁盘上完好的课表。
    private var allowEmptyWrite = false

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
    /// 快递取件列表（独立持久化 parcels.json）
    @Published var parcels: [ParcelItem] = []
    /// 待处理的快递短信全文（URL scheme 快捷指令入口传入；ParcelSection 消费后置 nil，不持久化）
    @Published var pendingParcelSMS: String? = nil
    /// 记账流水（独立持久化 ledger.json）
    @Published var ledgerEntries: [LedgerEntry] = []
    /// 作业列表变化钩子（解耦设计）：主 App 注入，用于重建 DDL 分级提醒通知
    static var onHomeworksChanged: (() -> Void)?
    /// 快递列表变化钩子（解耦设计）：主 App 注入，用于重建取件提醒通知
    static var onParcelsChanged: (() -> Void)?
    /// 课程列表变化钩子（解耦设计）：主 App 注入，服务器模式开启时即时推送课表到后端
    static var onCoursesChanged: (() -> Void)?
    // 多课程表变更钩子：主 App 注入，触发本地通知按当前活动课表重建
    static var onTimetablesChanged: (() -> Void)?
    /// 账本增删钩子：added = 新增的那笔（nil 表示是删除）；deletedId = 被删的本地 id。
    /// 主 App 注入后把变更同步到服务器（多端统一账本）；扩展进程不注入，保持 nil。
    static var onLedgerChanged: ((_ added: LedgerEntry?, _ deletedId: String?) -> Void)?
    /// 宠物等级（UserDefaults 独立持久化，每 30 EXP 升一级）
    @Published var petLevel: Int = 1
    /// 宠物当前经验（0 ~ expPerLevel-1，UserDefaults 独立持久化）
    @Published var petExp: Int = 0
    /// 每升一级所需经验值
    static let expPerLevel = 30

    /// 课程表列表（2026-10-13 起支持多课程表）
    @Published var timetables: [Timetable] = []
    /// 当前激活课程表的 id；nil = 尚未创建任何课程表
    @Published var activeTimetableId: String? = nil
    /// 当前激活课程表的名称（缓存显示用，避免视图层频繁遍历 timetables）
    @Published private(set) var activeTimetableName: String = ""

    /// 初始化：解析存储位置（App Group 优先，不可用时自动降级本地沙盒，数据不丢失）
    private init() {
        if let container = StorageLocation.containerURL {
            containerDirectory = container.appendingPathComponent("Documents")
            userDefaults = UserDefaults(suiteName: DataManager.appGroupID)
            print("[DataManager] ✅ App Group 共享存储：\(container.path)")
        } else {
            // 免费签名等场景 App Group 权限无效：降级到本地沙盒，
            // 旧实现此时静默放弃持久化（杀后台数据全丢）
            containerDirectory = StorageLocation.documentsDirectory
            userDefaults = StorageLocation.defaults
            print("[DataManager] ⚠️ App Group 不可用，降级本地存储：\(containerDirectory?.path ?? "")")
        }
        // 冷启动时从磁盘加载 @Published 镜像属性，避免首帧显示默认值
        syncPublished(from: loadState())
        // 加载作业待办列表（独立 JSON 文件）
        homeworks = loadHomeworks()
        // 加载快递与记账列表（loadList 内部解码 [T]，这里传元素类型而非数组类型）
        parcels = loadList("parcels.json", ParcelItem.self)
        // 快递超期自动清理：超过 15 天的快递无论取没取都删掉（避免列表越堆越长）
        let (cleaned, didExpire) = cleanupExpiredParcels(parcels)
        parcels = cleaned
        if didExpire {
            persistList(parcels, "parcels.json")
        }
        ledgerEntries = loadList("ledger.json", LedgerEntry.self)
        // 加载宠物等级与经验（UserDefaults 独立持久化；缺键时 integer 返回 0，需兜底）
        petLevel = (userDefaults?.object(forKey: Keys.petLevel.rawValue) as? Int) ?? 1
        petExp = (userDefaults?.object(forKey: Keys.petExp.rawValue) as? Int) ?? 0
    }

    // MARK: - 应用状态
    /// 加载完整 AppState
    /// 多候选解码：主目录 / 沙盒目录 / 各自的 .bak 轮着试，任意一份能解出来就用。
    /// 旧实现在唯一那份数据解码失败时直接返回空 fallback，而调用方（视图任意一次保存）
    /// 会把这个空状态写回磁盘 → 课表被永久清空（"隔一段时间课表就消失"的真实成因）。
    func loadState() -> AppState {
        for candidate in loadJSONCandidates() {
            if let state = try? JSONDecoder().decode(AppState.self, from: candidate.data) {
                if candidate.isBackup {
                    print("[DataManager] ⚠️ 主文件损坏，已从备份 \(candidate.url.lastPathComponent) 恢复")
                    // 把好数据写回主文件，下次启动直接命中（不轮转 .bak，那份是唯一好数据）
                    writePrimaryOnly(candidate.data)
                }
                return normalize(state)
            } else {
                print("[DataManager] 解码失败：\(candidate.url.path)（\(candidate.data.count) 字节）")
            }
        }

        // 磁盘读取或解码失败时回退到内存镜像，避免把已有数据清空。
        // 注意：必须把全部 @Published 镜像救回，不能只救 courses——
        // 旧实现只救课程，学期开始日期/宠物名/形象等会被静默打回默认值
        // （表现为：设置了开学日期但课表永远显示第 1 周，且设置活不过一次失败加载）。
        var fallback = AppState.default
        fallback.courses = courses
        fallback.semester.startDate = semesterStartDate
        fallback.pet.name = petName
        fallback.pet.mood = petMood
        fallback.pet.affection = petAffection
        fallback.pet.food = petFood
        fallback.pet.currentAction = petCurrentAction
        fallback.pet.bubbleText = petBubbleText
        fallback.settings.animSpeed = animSpeed
        fallback.settings.charId = charId
        fallback.settings.darkMode = darkMode
        fallback.settings.reminderEnabled = reminderEnabled
        // 多课程表也要救：旧 fallback 漏了这两项，一次解码失败就把表列表清空，
        // 接着 savePublishedState 写回空 timetables，课表从此消失。
        fallback.timetables = timetables
        fallback.activeTimetableId = activeTimetableId
        // 走一遍规范化：把救回的课程包成表 / 首次安装建空表，
        // 保证 UI 拿到的状态永远有活动课表（否则课表页显示"未命名"且无法导入）
        return normalize(fallback)
    }

    /// 迁移与一致性修正（原 loadState 里的全部规范化逻辑）
    private func normalize(_ state: AppState) -> AppState {
        var merged = mergeDefaults(state)
        // 多课程表迁移：老 JSON 缺 timetables 时，把已有 courses + semester.startDate
        // 包成一张默认课表，并设为活动课表。新建空 AppState 后做迁移，迁移后回填。
        if merged.timetables.isEmpty && !merged.courses.isEmpty {
            // 使用稳定的 id（基于开学日期字符串），避免每次冷启动迁移都建一张新表
            let stableId = stableIdFrom(startDate: merged.semester.startDate)
            let defaultTable = Timetable(
                id: stableId,
                name: "当前学期",
                startDate: merged.semester.startDate,
                courses: merged.courses,
                createdAt: Date()
            )
            merged.timetables = [defaultTable]
            merged.activeTimetableId = stableId
        } else if merged.timetables.isEmpty {
            // 完全没课表、没课程的首次安装：建一张空表，避免 UI 空指针
            let firstId = "first-\(UUID().uuidString.prefix(8))"
            let firstTable = Timetable(
                id: firstId,
                name: defaultTimetableName(),
                startDate: merged.semester.startDate.isEmpty ? todayString() : merged.semester.startDate,
                courses: [],
                createdAt: Date()
            )
            merged.timetables = [firstTable]
            merged.activeTimetableId = firstId
        } else if merged.activeTimetableId == nil || merged.timetables.first(where: { $0.id == merged.activeTimetableId }) == nil {
            // 有表但 activeId 失效（指向已删表）：回落到第一张
            merged.activeTimetableId = merged.timetables.first?.id
        }
        // 用活动课表内容回填顶层镜像；但**活动表为空而顶层有课**时不能反向覆盖——
        // 那是"顶层已有课、表还没跟上"的中间态，覆盖会把刚导入的课程抹掉。
        if let activeId = merged.activeTimetableId,
           let active = merged.timetables.first(where: { $0.id == activeId }) {
            if !active.courses.isEmpty || merged.courses.isEmpty {
                merged.courses = active.courses
            } else {
                // 顶层有课、活动表为空 → 以顶层为准，稍后由 savePublishedState 写回表
                print("[DataManager] 活动表为空但顶层有 \(merged.courses.count) 门课，保留顶层")
            }
            if !active.startDate.isEmpty { merged.semester.startDate = active.startDate }
        }
        // 双存储互备：JSON 里开学日期为空但 UserDefaults 有值时兜底恢复
        //（saveState 每次都同步写 UserDefaults，防 JSON 链路丢值导致课表永远第 1 周）
        if merged.semester.startDate.isEmpty {
            if let saved = userDefaults?.string(forKey: Keys.semesterStartDate.rawValue), !saved.isEmpty {
                merged.semester.startDate = saved
            } else if let std = UserDefaults.standard.string(forKey: Keys.semesterStartDate.rawValue),
                      !std.isEmpty {
                // suite 静默丢键时从 standard 双写兜底救回
                merged.semester.startDate = std
            }
        }
        return merged
    }

    /// 保存完整 AppState
    /// - Parameter triggerHook: 是否触发数据保存钩子（打字等高频保存场景可传 false，避免频繁重建通知）
    func saveState(_ state: AppState, triggerHook: Bool = true) {
        // 空覆盖护栏：内存里课表空了、磁盘上却有课，且本次不是用户显式清空 →
        // 拒绝写入。这条拦住的是"解码失败 → 空状态 → 任意一次保存 → 磁盘被清空"的连锁。
        if !allowEmptyWrite,
           state.courses.isEmpty,
           state.timetables.allSatisfy({ $0.courses.isEmpty }),
           diskHasNonEmptyCourses() {
            print("[DataManager] ⛔️ 拦住一次空课表覆盖（内存为空但磁盘有课），疑似异常状态，本次不写盘")
            return
        }
        do {
            let data = try JSONEncoder().encode(state)
            saveJSON(data)
            // 同步 UserDefaults 元数据（日期等）
            syncUserDefaults(from: state)
            // 同步 @Published 镜像属性，触发所有订阅视图刷新
            syncPublished(from: state)
            // 课表重新有内容 → 撤销"用户主动清空"标记（下次真丢数据仍会自动恢复）
            clearCoursesClearedMarkIfNeeded()
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
        // 多课程表：把当前活动课表的内容写回 timetables 列表
        // （视图层改课程/学期日期时只更新了镜像，必须把镜像同步回活动表里）
        if let activeId = activeTimetableId,
           let idx = s.timetables.firstIndex(where: { $0.id == activeId }) {
            var t = s.timetables[idx]
            t.courses = courses
            t.startDate = semesterStartDate
            s.timetables[idx] = t
        }
        s.timetables = timetables
        s.activeTimetableId = activeTimetableId
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
        Self.onCoursesChanged?()
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
        Self.onCoursesChanged?()
    }

    /// 更新课程（编辑保存）：按 id 原位替换，保持列表顺序
    func updateCourse(_ course: Course) {
        if let index = courses.firstIndex(where: { $0.id == course.id }) {
            courses[index] = course
            savePublishedState()
            Self.onCoursesChanged?()
        }
    }

    /// 删除单门课程（课表点击课程块 → 删除）
    func removeCourse(withId id: String) {
        courses.removeAll { $0.id == id }
        savePublishedState()
        Self.onCoursesChanged?()
    }

    /// 清空全部课程数据（保留宠物与设置），并通知界面刷新
    func clearCourses() {
        courses = []
        // 记录"用户主动清空"：冷启动自愈据此跳过服务器恢复，否则清了重启又回来
        markCoursesClearedByUser()
        // 用户显式清空：打开空覆盖开关，否则会被 saveState 的空覆盖护栏拦下
        allowEmptyWrite = true
        savePublishedState()
        allowEmptyWrite = false
        // 显式触发一次钩子，确保课程清空后本地提醒一定被重建（refreshAll 幂等，重复调用无害）
        Self.onStateSaved?()
    }

    private func markCoursesClearedByUser() {
        let ts = Date().timeIntervalSince1970
        userDefaults?.set(ts, forKey: Keys.coursesClearedAt.rawValue)
        UserDefaults.standard.set(ts, forKey: Keys.coursesClearedAt.rawValue)
    }

    /// 用户最近是否主动清空过课表（7 天窗口）：是则冷启动不要自动从服务器恢复。
    /// 窗口不宜长——清空过一周后若真丢数据，自动恢复应当生效。
    var userClearedCoursesRecently: Bool {
        let ts = userDefaults?.double(forKey: Keys.coursesClearedAt.rawValue)
            ?? UserDefaults.standard.double(forKey: Keys.coursesClearedAt.rawValue)
        guard ts > 0 else { return false }
        return Date().timeIntervalSince1970 - ts < 7 * 86400
    }

    /// 课表重新有数据了 → 撤销"主动清空"标记（下次丢数据仍能自动恢复）
    private func clearCoursesClearedMarkIfNeeded() {
        guard !courses.isEmpty else { return }
        userDefaults?.removeObject(forKey: Keys.coursesClearedAt.rawValue)
        UserDefaults.standard.removeObject(forKey: Keys.coursesClearedAt.rawValue)
    }

    /// 从服务器恢复课表：把服务器返回的课程合并回本地（按 名称+星期+开始时间 去重，避免重复），
    /// 同时写回当前活动课程表与开学日期。用于"本地数据丢失（重装/清缓存）后从服务器找回"。
    /// - Returns: 实际新增的课程数量（0 表示服务器也没有这门课，或本地已全有）
    @discardableResult
    func restoreCoursesFromServer(_ rawCourses: [[String: Any]], semesterStartDate: String) -> Int {
        var incoming: [Course] = []
        for c in rawCourses {
            guard let name = c["name"] as? String, !name.isEmpty,
                  let day = c["day_of_week"] as? Int, (1...7).contains(day),
                  let start = c["start_time"] as? String, !start.isEmpty,
                  let end = c["end_time"] as? String, !end.isEmpty else { continue }
            let teacher = c["teacher"] as? String ?? ""
            let location = c["location"] as? String ?? ""
            let parityRaw = c["week_parity"] as? String ?? "all"
            let parity: WeekParity = parityRaw == "all" ? .both : (WeekParity(rawValue: parityRaw) ?? .both)
            incoming.append(Course(name: name, teacher: teacher, location: location,
                                   dayOfWeek: day, startTime: start, endTime: end,
                                   weekParity: parity))
        }
        guard !incoming.isEmpty else { return 0 }
        // 合并：本地已有的不动，服务器有但本地没有的追加（去重键 = 名称+星期+开始时间）
        let existingKeys = Set(courses.map { "\($0.name)|\($0.dayOfWeek)|\($0.startTime)" })
        var merged = courses
        var added = 0
        for c in incoming where !existingKeys.contains("\(c.name)|\(c.dayOfWeek)|\(c.startTime)") {
            merged.append(c)
            added += 1
        }
        courses = merged
        if !semesterStartDate.isEmpty { self.semesterStartDate = semesterStartDate }
        savePublishedState()
        Self.onCoursesChanged?()
        return added
    }

    // MARK: - 多课程表 CRUD
    /// 当前激活课程表（只读视图层访问）
    var activeTimetable: Timetable? {
        guard let activeId = activeTimetableId else { return nil }
        return timetables.first(where: { $0.id == activeId })
    }

    /// 创建一张新课程表（不带课程，用于"先建表后导课"流程）。
    /// 默认按当前学期开学日期复制；返回新表的 id。
    @discardableResult
    func createTimetable(name: String, startDate: String? = nil, copyCoursesFromActive: Bool = false) -> String {
        let resolvedStart = (startDate?.isEmpty == false ? startDate! : semesterStartDate)
        let resolvedName = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? defaultTimetableName()
            : name
        let seedCourses = copyCoursesFromActive ? (activeTimetable?.courses ?? []) : []
        let table = Timetable(
            name: resolvedName,
            startDate: resolvedStart.isEmpty ? todayString() : resolvedStart,
            courses: seedCourses
        )
        var list = timetables
        list.append(table)
        timetables = list
        activeTimetableId = table.id
        // 立刻同步当前活动表的内容到镜像（切表后页面立即刷新）
        if let t = timetables.first(where: { $0.id == table.id }) {
            courses = t.courses
            semesterStartDate = t.startDate
        }
        savePublishedState()
        Self.onTimetablesChanged?()
        return table.id
    }

    /// 切换到指定 id 的课程表（同步更新镜像、触发钩子）
    func switchTimetable(to id: String) {
        guard timetables.contains(where: { $0.id == id }) else { return }
        // 把当前内存镜像写回原活动表，避免切走时丢失未保存的修改
        if let prevId = activeTimetableId,
           let prevIdx = timetables.firstIndex(where: { $0.id == prevId }) {
            var prev = timetables[prevIdx]
            prev.courses = courses
            prev.startDate = semesterStartDate
            timetables[prevIdx] = prev
        }
        activeTimetableId = id
        if let t = timetables.first(where: { $0.id == id }) {
            courses = t.courses
            semesterStartDate = t.startDate
            activeTimetableName = t.name
        }
        savePublishedState()
        // 切表后课程列表变了，本地通知（基于课程数据）和多端同步都得重建
        Self.onCoursesChanged?()
        Self.onTimetablesChanged?()
        Self.onStateSaved?()
    }

    /// 重命名指定课程表（仅改名，不动课）
    func renameTimetable(id: String, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let idx = timetables.firstIndex(where: { $0.id == id }) else { return }
        timetables[idx].name = trimmed
        if activeTimetableId == id { activeTimetableName = trimmed }
        savePublishedState()
        Self.onTimetablesChanged?()
    }

    /// 删除一张课程表；最后一张不能删（避免 activeId 落空导致页面空白）
    func deleteTimetable(id: String) {
        guard timetables.count > 1,
              timetables.firstIndex(where: { $0.id == id }) != nil else { return }
        timetables.removeAll { $0.id == id }
        // 删的是活动表：切到第一张；删的不是活动表：保持原 activeId
        if activeTimetableId == id || activeTimetableId == nil {
            activeTimetableId = timetables.first?.id
            if let newId = activeTimetableId,
               let t = timetables.first(where: { $0.id == newId }) {
                courses = t.courses
                semesterStartDate = t.startDate
                activeTimetableName = t.name
            }
        }
        savePublishedState()
        Self.onTimetablesChanged?()
        Self.onCoursesChanged?()
        Self.onStateSaved?()
    }

    /// 基于开学日期生成稳定的默认表 id（迁移时用）。
    /// 老 JSON 缺 timetables 时，把已有 courses 包成一张"当前学期"表，id 必须稳定，
    /// 否则每次冷启动都会重新建一张新表（重复迁移），用户会看到多张同名表。
    private func stableIdFrom(startDate: String) -> String {
        let digits = startDate.filter { $0.isNumber }.prefix(8)
        if digits.count == 8 {
            return "legacy-\(digits)"
        }
        // 开学日期为空（极端情况）：兜底用字面常量，避免每次启动换 id
        return "legacy-fallback"
    }

    /// 默认课程表名（首次建表 / 用户清空名称时用）
    private func defaultTimetableName() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy 年 MM 月"
        fmt.locale = Locale(identifier: "zh_CN")
        return "\(fmt.string(from: Date()))学期"
    }

    /// 今日 "YYYY-MM-DD"（新建表时兜底日期用）
    private func todayString() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.string(from: Date())
    }

    /// 备份恢复后调用：从磁盘重载全部 @Published 镜像，让界面立即反映恢复的数据
    func reloadAll() {
        syncPublished(from: loadState())
        homeworks = loadHomeworks()
        petLevel = (userDefaults?.object(forKey: Keys.petLevel.rawValue) as? Int) ?? 1
        petExp = (userDefaults?.object(forKey: Keys.petExp.rawValue) as? Int) ?? 0
    }

    // MARK: - @Published 镜像同步
    /// 把 AppState 同步到 @Published 镜像属性（赋值自动触发 objectWillChange）
    private func syncPublished(from state: AppState) {
        courses = state.courses
        semesterStartDate = state.semester.startDate
        timetables = state.timetables
        activeTimetableId = state.activeTimetableId
        activeTimetableName = activeTimetable?.name ?? ""
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
        /// 用户最后一次"手动清空全部课程"的时间戳（秒）。
        /// 冷启动自愈靠它判断"本地空是用户主动清的"还是"数据被人为丢了"——
        /// 否则用户清了课表、重启 App 又被服务器自动恢复回来，等于清不掉。
        case coursesClearedAt = "courses.lastClearedAt"
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
        charId = id   // 同时更新 @Published 属性（触发 SwiftUI 刷新）
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
        Self.onHomeworksChanged?()
    }

    /// 切换作业完成状态
    func toggleHomework(id: String) {
        guard let index = homeworks.firstIndex(where: { $0.id == id }) else { return }
        homeworks[index].isDone.toggle()
        // 记录完成时间（每日任务"完成 1 个作业"联动判断用），取消完成时清空
        homeworks[index].completedAt = homeworks[index].isDone ? Date() : nil
        persistHomeworks()
        // 完成后撤销该作业的 DDL 提醒 / 未完成时恢复，统一走重建
        Self.onHomeworksChanged?()
    }

    /// 修改作业截止时间（Agent 管家用；nil = 清空截止）
    func updateHomeworkDue(id: String, due: Date?) {
        guard let index = homeworks.firstIndex(where: { $0.id == id }) else { return }
        homeworks[index].dueDate = due
        persistHomeworks()
        Self.onHomeworksChanged?()
    }

    /// 删除一条作业
    func deleteHomework(id: String) {
        homeworks.removeAll { $0.id == id }
        persistHomeworks()
        Self.onHomeworksChanged?()
    }

    /// 整体替换作业列表（平台同步合并专用）：与增删同一条持久化+通知链路
    func replaceAllHomeworks(_ items: [HomeworkItem]) {
        homeworks = items
        persistHomeworks()
        Self.onHomeworksChanged?()
    }

    // MARK: - 快递取件
    /// 超期天数（入库超过这个天数的快递自动删除，无论取没取）
    static let parcelExpireDays: Int = 15

    /// 清理超期快递：超过 15 天的无论取没取都删掉
    /// 返回：(清理后的列表, 是否删掉了条目)
    private func cleanupExpiredParcels(_ list: [ParcelItem]) -> ([ParcelItem], Bool) {
        let cutoff = Calendar.current.date(byAdding: .day, value: -Self.parcelExpireDays, to: Date()) ?? Date()
        let before = list.count
        let result = list.filter { $0.createdAt >= cutoff }
        let didExpire = result.count != before
        if didExpire {
            print("[DataManager] 清理超期快递：\(before)→\(result.count) 删了 \(before - result.count) 条（超过 \(Self.parcelExpireDays) 天）")
        }
        return (result, didExpire)
    }

    /// 新增一个快递
    func addParcel(_ item: ParcelItem) {
        parcels.insert(item, at: 0)
        persistList(parcels, "parcels.json")
        Self.onParcelsChanged?()
    }

    /// 标记取件 / 取消标记
    func toggleParcelPicked(id: String) {
        guard let index = parcels.firstIndex(where: { $0.id == id }) else { return }
        parcels[index].pickedAt = parcels[index].pickedAt == nil ? Date() : nil
        persistList(parcels, "parcels.json")
        Self.onParcelsChanged?()
    }

    /// 删除一个快递
    func deleteParcel(id: String) {
        parcels.removeAll { $0.id == id }
        persistList(parcels, "parcels.json")
        Self.onParcelsChanged?()
    }

    // MARK: - 记账
    /// 新增一笔支出
    func addLedgerEntry(_ entry: LedgerEntry) {
        ledgerEntries.insert(entry, at: 0)
        persistList(ledgerEntries, "ledger.json")
        Self.onLedgerChanged?(entry, nil)
    }

    /// 删除一笔支出
    func deleteLedgerEntry(id: String) {
        ledgerEntries.removeAll { $0.id == id }
        persistList(ledgerEntries, "ledger.json")
        Self.onLedgerChanged?(nil, id)
    }

    /// 批量替换账本（服务器拉取后对齐本地用）；不触发 onLedgerChanged，避免回环同步
    func replaceLedgerEntries(_ entries: [LedgerEntry]) {
        ledgerEntries = entries
        persistList(ledgerEntries, "ledger.json")
    }

    /// 本月支出总额
    func monthTotal() -> Double {
        let cal = Calendar.current
        let now = Date()
        return ledgerEntries
            .filter { cal.isDate($0.date, equalTo: now, toGranularity: .month) }
            .reduce(0) { $0 + $1.amount }
    }

    /// 把作业列表写入存储目录的 homeworks.json
    private func persistHomeworks() {
        guard let dir = ensureContainerDirectory() else { return }
        guard let data = try? JSONEncoder().encode(homeworks) else { return }
        try? data.write(to: dir.appendingPathComponent("homeworks.json"))
    }

    /// 通用列表持久化：写入存储目录的指定 JSON 文件
    private func persistList<T: Encodable>(_ items: [T], _ filename: String) {
        guard let dir = ensureContainerDirectory() else { return }
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: dir.appendingPathComponent(filename))
    }

    /// 通用列表读取：文件不存在或解码失败返回空数组
    private func loadList<T: Decodable>(_ filename: String, _ type: T.Type) -> [T] {
        guard let dir = containerDirectory else { return [] }
        let url = dir.appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: url),
              let items = try? JSONDecoder().decode([T].self, from: data) else { return [] }
        return items
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
            version: state.version,
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
            ),
            timetables: state.timetables,
            activeTimetableId: state.activeTimetableId
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
        // standard 双写兜底：suite 对象即使 entitlement 无效也非 nil，写入可能被系统静默丢弃
        //（这正是"设置了开学日期但课表永远第 1 周"的头号嫌疑），焦点键双写保证可恢复
        UserDefaults.standard.set(state.semester.startDate, forKey: Keys.semesterStartDate.rawValue)
        print("[DataManager] syncUserDefaults semester.startDate='\(state.semester.startDate)' suite=\(userDefaults?.string(forKey: Keys.semesterStartDate.rawValue) ?? "nil") standard=\(UserDefaults.standard.string(forKey: Keys.semesterStartDate.rawValue) ?? "nil")")
    }

    /// 数据目录列表：App Group Documents + 沙盒 Documents/AppData（去重）。
    /// App Group 不可用时 containerDirectory 本身就是沙盒目录，去重避免同一文件写两遍。
    private func storageDirectories() -> [URL] {
        let fm = FileManager.default
        var dirs: [URL] = []
        if let dir = containerDirectory { dirs.append(dir) }
        let sandboxBase = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AppData", isDirectory: true)
        if !dirs.contains(where: { $0.standardizedFileURL.path == sandboxBase.standardizedFileURL.path }) {
            dirs.append(sandboxBase)
        }
        return dirs
    }

    /// 候选数据源（按"主文件优先、备份其次"排序，主文件内部按 mtime 新→旧）。
    /// 双目录 + 双备份 = 最多四份候选：一次写入被打断/文件被截断，仍有另一份可用，
    /// 不会出现"唯一那份坏了 → 空状态 → 覆盖写 → 课表彻底消失"。
    private func loadJSONCandidates() -> [(url: URL, data: Data, isBackup: Bool)] {
        let fm = FileManager.default
        var mains: [(url: URL, data: Data, mtime: Date)] = []
        var baks: [(url: URL, data: Data, mtime: Date)] = []
        for dir in storageDirectories() {
            for (name, isBak) in [("courses.json", false), ("courses.json.bak", true)] {
                let url = dir.appendingPathComponent(name)
                guard let data = try? Data(contentsOf: url) else { continue }
                let attr = try? fm.attributesOfItem(atPath: url.path)
                let mtime = (attr?[.modificationDate] as? Date) ?? .distantPast
                if isBak { baks.append((url, data, mtime)) } else { mains.append((url, data, mtime)) }
            }
        }
        mains.sort { $0.mtime > $1.mtime }
        baks.sort { $0.mtime > $1.mtime }
        let out = mains.map { (url: $0.url, data: $0.data, isBackup: false) }
            + baks.map { (url: $0.url, data: $0.data, isBackup: true) }

        let desc = out.map { "\($0.isBackup ? "bak:" : "")\($0.url.deletingLastPathComponent().lastPathComponent)(\($0.data.count)B)" }
            .joined(separator: " ")
        print("[DataManager] 数据候选 \(out.count) 份：\(desc.isEmpty ? "无" : desc)")
        return out
    }

    /// 从备份恢复时只写主文件（不轮转 .bak）：此刻 .bak 就是唯一的好数据，
    /// 若走正常保存路径会拿坏的主文件把它覆盖掉。
    private func writePrimaryOnly(_ data: Data) {
        for dir in storageDirectories() {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? data.write(to: dir.appendingPathComponent("courses.json"), options: .atomic)
        }
    }

    /// 磁盘上是否存在"带课程的"状态（空覆盖护栏用）。
    /// 只在内存状态为空时才调用，读盘开销可以接受。
    private func diskHasNonEmptyCourses() -> Bool {
        for candidate in loadJSONCandidates() where !candidate.isBackup {
            guard let state = try? JSONDecoder().decode(AppState.self, from: candidate.data) else { continue }
            if !state.courses.isEmpty { return true }
            if state.timetables.contains(where: { !$0.courses.isEmpty }) { return true }
        }
        return false
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
        // 双写策略：主目录 + 本地降级目录都写（后者永远写）。
        // App Group 半失效时 Data.write 可能"报成功"但内容被系统吞——
        // 本地降级目录的那份是唯一可靠的最新数据源。
        // 每份都：先把旧文件滚动成 .bak（只留一代），再原子写主文件。
        // 原子写（.atomic）先落临时文件再 rename，进程被系统杀掉也不会留下半截 JSON。
        let fm = FileManager.default
        for dir in storageDirectories() {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("courses.json")
            let bak = dir.appendingPathComponent("courses.json.bak")
            if fm.fileExists(atPath: url.path) {
                // 轮转前先确认旧文件本身是好的：坏文件绝不能覆盖唯一可用的 .bak，
                // 否则"主文件损坏 → 一次保存 → 备份也被污染"，两份全废。
                let old = try? Data(contentsOf: url)
                let decodable = old.flatMap { try? JSONDecoder().decode(AppState.self, from: $0) } != nil
                if decodable {
                    try? fm.removeItem(at: bak)
                    try? fm.copyItem(at: url, to: bak)
                } else {
                    let corrupt = dir.appendingPathComponent("courses.json.corrupt")
                    try? fm.removeItem(at: corrupt)
                    try? fm.moveItem(at: url, to: corrupt)
                    print("[DataManager] 旧文件无法解码，已改名保留为 courses.json.corrupt（不覆盖 .bak）")
                }
            }
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                print("[DataManager] 写入失败 \(url.path)：\(error)")
            }
        }
    }
}
