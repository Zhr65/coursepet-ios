// MARK: - 养成面板（对应 prototype/js/ui/feed.js）
import SwiftUI
import Shared

struct FeedView: View {
    @EnvironmentObject var dataManager: DataManager
    @State private var showPetInteraction = false

    private var state: AppState { dataManager.loadState() }
    private var pet: PetState { state.pet }
    private var settings: AppSettings { state.settings }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // ── 宠物展示区 ──
                petDisplayArea

                // ── 状态统计 ──
                statsSection

                // ── 操作按钮 ──
                actionButtons
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .navigationTitle(pet.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - 宠物展示区
    private var petDisplayArea: some View {
        VStack(spacing: 12) {
            // 宠物大图（可点击互动）
            ZStack {
                Circle()
                    .fill(Color.orange.opacity(0.15))
                    .frame(width: 160, height: 160)

                PetAnimationView(
                    action: pet.currentAction,
                    charId: settings.charId,
                    speed: settings.animSpeed,
                    size: 140,
                    loop: true
                )
                .onTapGesture {
                    petInteract()
                }
            }

            // 气泡文字
            PetBubble(
                text: pet.bubbleText,
                isVisible: !pet.bubbleText.isEmpty
            )
            .padding(.horizontal, 40)
        }
        .padding(.vertical, 24)
        .background(Color(.systemBackground))
        .cornerRadius(16)
        .shadow(radius: 2)
    }

    // MARK: - 状态统计
    private var statsSection: some View {
        HStack(spacing: 0) {
            statCard(title: "心情", value: pet.mood, color: .pink, icon: "heart.fill")
                .frame(maxWidth: .infinity)
            Divider().frame(height: 40)
            statCard(title: "好感度", value: pet.affection, color: .purple, icon: "star.fill")
                .frame(maxWidth: .infinity)
            Divider().frame(height: 40)
            statCard(title: "食物", value: pet.food, color: .orange, icon: "cpu.fill")
                .frame(maxWidth: .infinity)
        }
        .background(Color(.systemBackground))
        .cornerRadius(16)
        .shadow(radius: 2)
    }

    private func statCard(title: String, value: Int, color: Color, icon: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(color)
            Text("\(value)")
                .font(.title)
                .fontWeight(.bold)
                .foregroundColor(.primary)
            Text(title)
                .font(.caption2)
                .foregroundColor(.secondary)
            // 进度条
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color.opacity(0.15))
                        .frame(height: 4)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color)
                        .frame(width: geo.size.width * CGFloat(min(100, max(0, value))) / 100.0, height: 4)
                }
            }
            .frame(height: 4)
            .frame(maxWidth: .infinity)
        }
        .padding(.vertical, 8)
    }

    // MARK: - 操作按钮
    private var actionButtons: some View {
        VStack(spacing: 12) {
            Button {
                feedPet()
            } label: {
                HStack {
                    Image(systemName: "cup.and.saucer.fill")
                    Text("喂食（-1 食物 +10 心情）")
                }
                .font(.body)
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color.orange)
                .foregroundColor(.white)
                .cornerRadius(12)
            }
            .disabled(pet.food <= 0)
            .opacity(pet.food <= 0 ? 0.5 : 1.0)

            Button {
                checkIn()
            } label: {
                HStack {
                    Image(systemName: "checkmark.seal.fill")
                    Text("上课打卡（获得 1 食物）")
                }
                .font(.body)
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color.green)
                .foregroundColor(.white)
                .cornerRadius(12)
            }
        }
        .background(Color(.systemBackground))
        .cornerRadius(16)
        .shadow(radius: 2)
    }

    // MARK: - 操作逻辑
    private func feedPet() {
        guard pet.food > 0 else {
            showToast("没有食物啦，快去上课打卡！")
            return
        }
        var s = state
        s.pet.food -= 1
        s.pet.mood = min(100, s.pet.mood + 10)
        s.pet.affection = min(100, s.pet.affection + 2)
        dataManager.saveState(s)
        showToast("\(s.pet.name) 开心地吃掉了食物！")
    }

    private func checkIn() {
        let semesterStart = dataManager.getSemesterStartDate() ?? ""
        guard !semesterStart.isEmpty else {
            showToast("请先在设置中填写学期开始日期")
            return
        }
        let weekNum = WeekMath.currentWeekNumber(startDateStr: semesterStart) ?? 1
        let weekCourses = ScheduleHelpers.courses(forWeek: weekNum, courses: state.courses)
        let result = ScheduleHelpers.currentAndNext(courses: weekCourses, at: Date())
        guard result.current != nil else {
            showToast("现在没有在上课哦，打卡失败")
            return
        }
        var s = state
        s.pet.food += 1
        s.pet.mood = min(100, s.pet.mood + 10)
        s.pet.affection = min(100, s.pet.affection + 5)
        dataManager.saveState(s)
        showToast("打卡成功！获得 1 个食物 🍙")
    }

    private func petInteract() {
        // 随机触发动作 + 震动反馈
        let result = PetStateManager.decideAction(
            courses: state.courses,
            charging: settings.simCharging,
            lowBattery: settings.simLowBattery,
            musicPlaying: settings.simMusic,
            lastClickAt: Date()
        )
        var s = state
        s.pet.currentAction = result.action
        s.pet.bubbleText = result.bubble
        dataManager.saveState(s)
        dataManager.setCurrentAction(result.action)
        dataManager.setBubbleText(result.bubble)
        // 震动反馈
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.impactOccurred()
    }

    private func showToast(_ message: String) {
        // 实际项目中可用 Toast 视图
    }
}
