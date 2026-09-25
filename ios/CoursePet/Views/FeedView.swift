// MARK: - 宠物养成 + 每日任务体系（液态玻璃风重设计）
// 结构：宠物大卡（等级徽章 + EXP 进度条 + 点击互动）→ 每日任务卡 → 数据条 → 成就墙
// EXP 来源：每日签到 +5、完成作业 +8（TodoView）、专注完成 +15（FocusView）、点击喂食 +2
import SwiftUI

struct FeedView: View {
    @EnvironmentObject var dataManager: DataManager
    // Toast 提示
    @State private var toastMessage: String?
    // 每日签到状态
    @State private var checkInStreak: Int = 0
    @State private var checkedInToday: Bool = false
    // 待机趣味气泡（onAppear 随机选一条，互动气泡优先显示）
    @State private var funBubble: String = ""
    // 点击宠物后的临时气泡
    @State private var tapBubble: String = ""
    // 已解锁成就 id 集合（成就墙渲染用）
    @State private var unlockedIds: Set<String> = []
    // 宠物当前动作（点击后 happy，1.5 秒后回 idle）
    @State private var petAction: String = "idle"
    // 动画重启令牌：改变 id 强制重建宠物视图，让 happy 动画每次都从头播
    @State private var petToken: Int = 0

    // 待机趣味语料库（onAppear 随机挑一条展示）
    private static let funBubbles: [String] = [
        "今天也要加油鸭！",
        "作业写完了吗👀",
        "陪我玩一会儿嘛～",
        "记得多喝水哦！",
        "别熬太晚，早点休息～",
        "今天上课有认真听吗？",
        "想去操场晒太阳～",
        "你是最棒的主人！",
        "饿了饿了，快喂我～",
        "一起努力变优秀吧！",
    ]
    // 点击宠物时的随机语
    private static let tapBubbles: [String] = [
        "开心～谢谢你陪我玩！",
        "嘿嘿，最喜欢你啦！",
        "好耶！一起加油！",
        "摸摸头，心情变好了～",
        "咔嚓！存起来一点开心 ✨",
    ]

    var body: some View {
        ZStack {
            // 柔和渐变背景：玻璃卡透出背景色
            LinearGradient(colors: PagePalette.feed, startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 16) {
                    headerBar        // 大标题 + 副标题
                    petCard          // 宠物大卡（等级 + EXP）
                    dailyTasksCard   // 每日任务
                    statsRow         // 心情/好感/食物小图标行
                    achievementWall  // 成就墙
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 24)
            }
        }
        .onAppear {
            refreshCheckInState()
            refreshAchievements()
            funBubble = Self.funBubbles.randomElement() ?? ""
        }
        .overlay(alignment: .bottom) { toastOverlay }
    }

    // MARK: - 顶部大标题
    private var headerBar: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("养成")
                .font(.title)
                .fontWeight(.bold)
            Text("完成任务赚 EXP，陪宠物一起成长")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 宠物大卡（等级徽章 + EXP 进度条 + 点击互动）
    private var petCard: some View {
        GlassCard {
            VStack(spacing: 12) {
                // 等级徽章 + EXP 数值
                HStack {
                    Text("Lv.\(dataManager.petLevel)")
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule().fill(
                                LinearGradient(colors: [Color.purple, Color.indigo],
                                               startPoint: .leading, endPoint: .trailing)
                            )
                        )
                    Spacer()
                    Text("\(dataManager.petExp)/\(DataManager.expPerLevel) EXP")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                // 宠物本体（可点击：开心动画 + 随机语 + 触觉 + 喂食加成）
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.35))
                        .frame(width: 150, height: 150)
                    PetAnimationView(
                        action: petAction,
                        charId: dataManager.charId,
                        speed: dataManager.animSpeed,
                        size: 130,
                        loop: true
                    )
                    // id 变化时重建视图重启动画
                    .id("pet-\(petAction)-\(dataManager.charId)-\(dataManager.animSpeed)-\(petToken)")
                    .onTapGesture { petTap() }
                }

                // 气泡：互动气泡优先，否则展示待机趣味语
                Text(tapBubble.isEmpty ? funBubble : tapBubble)
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)

                // EXP 进度条
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.purple.opacity(0.15))
                        Capsule()
                            .fill(
                                LinearGradient(colors: [Color.purple, Color.indigo],
                                               startPoint: .leading, endPoint: .trailing)
                            )
                            .frame(width: expProgress * geo.size.width)
                    }
                }
                .frame(height: 8)
                .animation(.easeInOut(duration: 0.3), value: dataManager.petExp)
            }
        }
    }

    /// EXP 进度比例（0 ~ 1）
    private var expProgress: CGFloat {
        CGFloat(min(dataManager.petExp, DataManager.expPerLevel)) / CGFloat(DataManager.expPerLevel)
    }

    // MARK: - 每日任务卡
    private var dailyTasksCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundColor(.green)
                    Text("每日任务")
                        .font(.headline)
                    Spacer()
                    Text("已连续签到 \(checkInStreak) 天")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                ForEach(dailyTasks) { task in
                    taskRow(task)
                }
            }
        }
    }

    /// 每日任务数据模型
    private struct DailyTask: Identifiable {
        let id: String
        let icon: String
        let title: String
        let exp: Int
        let done: Bool
        /// 是否可点击触发（仅签到可点击，其余自动勾选）
        let tappable: Bool
    }

    /// 三项每日任务（签到/作业/专注联动各自的真实数据）
    private var dailyTasks: [DailyTask] {
        [
            DailyTask(id: "checkin", icon: "hand.tap.fill", title: "每日签到", exp: 5,
                      done: checkedInToday, tappable: true),
            DailyTask(id: "homework", icon: "book.fill", title: "完成 1 个作业", exp: 8,
                      done: homeworkDoneToday, tappable: false),
            DailyTask(id: "focus", icon: "timer", title: "专注 25 分钟", exp: 15,
                      done: focusDoneToday, tappable: false),
        ]
    }

    /// 今天是否完成过至少 1 个作业（HomeworkItem.completedAt 记录完成时间）
    private var homeworkDoneToday: Bool {
        dataManager.homeworks.contains { item in
            guard item.isDone, let completedAt = item.completedAt else { return false }
            return Calendar.current.isDateInToday(completedAt)
        }
    }

    /// 今天是否完成过专注（FocusView 完成时写入 lastFocusDate）
    private var focusDoneToday: Bool {
        guard let last = dataManager.getLastFocusDate() else { return false }
        return Calendar.current.isDateInToday(last)
    }

    /// 单行任务：奖励 EXP + 完成状态勾选
    private func taskRow(_ task: DailyTask) -> some View {
        HStack(spacing: 12) {
            Image(systemName: task.icon)
                .font(.body)
                .foregroundColor(task.done ? .green : .indigo)
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text("+\(task.exp) EXP")
                    .font(.caption2)
                    .foregroundColor(.purple)
            }

            Spacer()

            if task.done {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
            } else {
                Circle()
                    .stroke(Color.secondary.opacity(0.4), lineWidth: 1.5)
                    .frame(width: 18, height: 18)
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture {
            // 只有未完成的签到可点击；作业/专注由对应功能自动勾选
            if task.tappable && !task.done {
                doCheckIn()
            }
        }
    }

    // MARK: - 数据条（心情/好感/食物，弱化为小图标行）
    private var statsRow: some View {
        GlassCard(padding: 12) {
            HStack(spacing: 0) {
                statChip(icon: "heart.fill", color: .pink, label: "心情 \(dataManager.petMood)")
                    .frame(maxWidth: .infinity)
                statChip(icon: "star.fill", color: .purple, label: "好感 \(dataManager.petAffection)")
                    .frame(maxWidth: .infinity)
                statChip(icon: "carrot.fill", color: .orange, label: "食物 \(dataManager.petFood)")
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func statChip(icon: String, color: Color, label: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.subheadline)
                .foregroundColor(color)
            Text(label)
                .font(.caption)
                .foregroundColor(.primary)
        }
    }

    // MARK: - 成就墙（保留原有逻辑与调用点）
    private var achievementWall: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "trophy.fill")
                        .foregroundColor(.yellow)
                    Text("成就墙")
                        .font(.headline)
                    Spacer()
                    Text("已解锁 \(unlockedIds.count)/\(AchievementManager.allAchievements.count)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                // 横向滚动的成就胶囊
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(AchievementManager.allAchievements) { achievement in
                            achievementCapsule(achievement)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    /// 单个成就胶囊：已解锁高亮彩色 + emoji，未解锁灰色 + 🔒
    private func achievementCapsule(_ achievement: AchievementManager.Achievement) -> some View {
        let unlocked = unlockedIds.contains(achievement.id)
        return HStack(spacing: 6) {
            Text(unlocked ? achievement.emoji : "🔒")
                .font(.body)
            VStack(alignment: .leading, spacing: 1) {
                Text(achievement.name)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(unlocked ? .primary : .secondary)
                Text(achievement.desc)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(unlocked ? Color.yellow.opacity(0.22) : Color(.systemGray6))
        .overlay(
            Capsule().stroke(unlocked ? Color.orange.opacity(0.6) : Color.clear, lineWidth: 1)
        )
        .clipShape(Capsule())
    }

    // MARK: - 成就相关辅助
    /// 从成就管理器刷新已解锁集合（成就墙渲染用）
    private func refreshAchievements() {
        unlockedIds = AchievementManager.unlockedIds()
    }

    /// 成就解锁 toast 文案："🏆 解锁成就：xxx"
    private func achievementToast(_ id: String) -> String {
        let achievement = AchievementManager.achievement(withID: id)
        return "🏆 解锁成就：\(achievement?.name ?? id)"
    }

    // MARK: - Toast 提示
    @ViewBuilder
    private var toastOverlay: some View {
        if let message = toastMessage {
            Text(message)
                .font(.subheadline)
                .foregroundColor(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color.black.opacity(0.75))
                .cornerRadius(20)
                .padding(.bottom, 24)
                .transition(.opacity)
        }
    }

    private func showToast(_ message: String) {
        withAnimation { toastMessage = message }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation {
                if toastMessage == message { toastMessage = nil }
            }
        }
    }

    // MARK: - 升级提示（Toast + 成功触觉）
    private func showLevelToastIfNeeded(_ leveled: Bool, fallback: String) {
        if leveled {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            showToast("🎉 宠物升到 Lv.\(dataManager.petLevel)！")
        } else {
            showToast(fallback)
        }
    }

    // MARK: - 签到状态刷新
    private func refreshCheckInState() {
        checkInStreak = dataManager.getCheckInStreak()
        if let last = dataManager.getLastCheckInDate() {
            checkedInToday = Calendar.current.isDate(last, inSameDayAs: Date())
        } else {
            checkedInToday = false
        }
    }

    // MARK: - 每日签到（每日任务第一项，+5 EXP）
    private func doCheckIn() {
        guard !checkedInToday else { return }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        // 连续天数：昨天签过则 +1，否则重新从 1 开始（保留原有 streak 逻辑）
        var newStreak = 1
        if let last = dataManager.getLastCheckInDate() {
            let lastDay = calendar.startOfDay(for: last)
            if calendar.isDate(lastDay, inSameDayAs: today) {
                newStreak = max(1, dataManager.getCheckInStreak())
            } else if let diff = calendar.dateComponents([.day], from: lastDay, to: today).day, diff == 1 {
                newStreak = dataManager.getCheckInStreak() + 1
            }
        }
        dataManager.setLastCheckInDate(Date())
        dataManager.setCheckInStreak(newStreak)
        checkInStreak = newStreak
        checkedInToday = true

        // 签到奖励：+1 食物、+10 心情、+5 好感，宠物开心
        var s = dataManager.loadState()
        s.pet.food += 1
        s.pet.mood = min(100, s.pet.mood + 10)
        s.pet.affection = min(100, s.pet.affection + 5)
        s.pet.currentAction = "happy"
        s.pet.bubbleText = "签到啦～最喜欢你啦！"
        dataManager.saveState(s)
        // 播放开心动画
        playHappyAnimation(bubble: "签到啦～最喜欢你啦！")

        // 触觉反馈
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()

        // 签到 +5 EXP
        let leveled = dataManager.addEXP(5)

        // 成就检查：首次签到 / 连续 3 天 / 连续 7 天（多个同时解锁时显示最后一个）
        var unlockedToast: String? = nil
        if AchievementManager.unlockIfNeeded("first_checkin") {
            unlockedToast = achievementToast("first_checkin")
        }
        if newStreak >= 3, AchievementManager.unlockIfNeeded("streak3") {
            unlockedToast = achievementToast("streak3")
        }
        if newStreak >= 7, AchievementManager.unlockIfNeeded("streak7") {
            unlockedToast = achievementToast("streak7")
        }
        refreshAchievements()

        if let toast = unlockedToast {
            showToast(toast)
        } else if leveled {
            showLevelToastIfNeeded(true, fallback: "")
        } else {
            showToast("签到成功！+5 EXP，连续 \(newStreak) 天 🍙")
        }
    }

    // MARK: - 点击宠物互动（食物 > 0 时消耗 1 食物 +2 EXP）
    private func petTap() {
        // 开心动画 + 随机语 + 触觉
        playHappyAnimation(bubble: Self.tapBubbles.randomElement() ?? "开心～")
        UIImpactFeedbackGenerator(style: .light).impactOccurred()

        guard dataManager.petFood > 0 else {
            showToast("食物不足，去完成任务吧 🍙")
            return
        }

        // 消耗 1 食物 + 少量心情（喂食逻辑：点击宠物即喂食）
        var s = dataManager.loadState()
        if s.pet.food > 0 {
            s.pet.food -= 1
            s.pet.mood = min(100, s.pet.mood + 5)
            s.pet.currentAction = "happy"
            dataManager.saveState(s)
        }
        // 喂食 +2 EXP
        let leveled = dataManager.addEXP(2)

        // 成就检查：第一次喂食（沿用原成就点）
        if AchievementManager.unlockIfNeeded("first_feed") {
            showToast("🏆 解锁成就：初次喂食")
            refreshAchievements()
            return
        }
        showLevelToastIfNeeded(leveled, fallback: "开心吃掉了！+2 EXP")
        refreshAchievements()
    }

    // MARK: - 开心动画播放（1.5 秒后回到 idle）
    private func playHappyAnimation(bubble: String) {
        tapBubble = bubble
        petAction = "happy"
        petToken += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            petAction = "idle"
            petToken += 1
        }
    }
}
