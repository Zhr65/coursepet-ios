// MARK: - 养成面板（对应 prototype/js/ui/feed.js）
import SwiftUI

struct FeedView: View {
    @EnvironmentObject var dataManager: DataManager
    // Toast 提示
    @State private var toastMessage: String?
    // 每日签到状态
    @State private var checkInStreak: Int = 0
    @State private var checkedInToday: Bool = false

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

                // ── 每日签到卡片 ──
                dailyCheckInCard

                // ── 喂食按钮 ──
                feedButton
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .navigationTitle(pet.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { refreshCheckInState() }
        .overlay(alignment: .bottom) { toastOverlay }
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
        .background(Color(.systemBackground).opacity(0.9))
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
        .background(Color(.systemBackground).opacity(0.9))
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

    // MARK: - 每日签到卡片
    private var dailyCheckInCard: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundColor(.green)
                Text("每日签到")
                    .font(.headline)
                Spacer()
                Text("已连续 \(checkInStreak) 天")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if checkedInToday {
                // 今天已签：展示连续天数
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("今日已签 ✓ 连续 \(checkInStreak) 天")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Spacer()
                }
            } else {
                // 今天未签：绿色可点按钮
                Button {
                    doCheckIn()
                } label: {
                    HStack {
                        Image(systemName: "hand.tap.fill")
                        Text("签到 +1 🍙")
                    }
                    .font(.body)
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.green)
                    .foregroundColor(.white)
                    .cornerRadius(10)
                }
            }
        }
        .padding()
        .background(Color(.systemBackground).opacity(0.9))
        .cornerRadius(16)
        .shadow(radius: 2)
    }

    // MARK: - 喂食按钮
    private var feedButton: some View {
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
        // 食物为 0 时禁用并置灰
        .disabled(pet.food <= 0)
        .opacity(pet.food <= 0 ? 0.5 : 1.0)
        .padding(12)
        .background(Color(.systemBackground).opacity(0.9))
        .cornerRadius(16)
        .shadow(radius: 2)
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

    // MARK: - 签到状态刷新
    private func refreshCheckInState() {
        checkInStreak = dataManager.getCheckInStreak()
        if let last = dataManager.getLastCheckInDate() {
            checkedInToday = Calendar.current.isDate(last, inSameDayAs: Date())
        } else {
            checkedInToday = false
        }
    }

    // MARK: - 每日签到
    private func doCheckIn() {
        guard !checkedInToday else { return }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        // 连续天数：昨天签过则 +1，否则重新从 1 开始
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

        // 签到奖励：+1 食物、+10 心情、+5 好感
        var s = state
        s.pet.food += 1
        s.pet.mood = min(100, s.pet.mood + 10)
        s.pet.affection = min(100, s.pet.affection + 5)
        s.pet.currentAction = "happy"
        s.pet.bubbleText = "签到啦～最喜欢你啦！"
        dataManager.saveState(s)

        // 触觉反馈
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.impactOccurred()
        showToast("签到成功！连续 \(newStreak) 天 🍙")
    }

    // MARK: - 操作逻辑
    private func feedPet() {
        guard pet.food > 0 else {
            showToast("没有食物啦，先去每日签到赚食物吧！")
            return
        }
        var s = state
        s.pet.food -= 1
        s.pet.mood = min(100, s.pet.mood + 10)
        s.pet.affection = min(100, s.pet.affection + 2)
        // 喂食后宠物播放开心动作
        s.pet.currentAction = "happy"
        s.pet.bubbleText = "好吃！谢谢你～"
        dataManager.saveState(s)

        // 触觉反馈
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.impactOccurred()
        showToast("\(s.pet.name) 开心地吃掉了食物！")
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
}
