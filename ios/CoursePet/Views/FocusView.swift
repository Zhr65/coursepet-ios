// MARK: - 专注番茄钟（替换原游戏 tab）
// 圆环倒计时（15/25/45 分钟可选），开始后宠物在下方陪伴（过半变 sleepy）；
// 完成 → +15 EXP +2 食物 + 触觉庆祝 + toast；中途放弃需 confirmationDialog 确认。
import SwiftUI

struct FocusView: View {
    @EnvironmentObject var dataManager: DataManager

    // 可选时长（分钟）
    private let durationOptions = [15, 25, 45]
    @State private var selectedMinutes: Int = 25
    // 倒计时状态
    @State private var totalSeconds: Int = 25 * 60
    @State private var remainingSeconds: Int = 25 * 60
    @State private var isRunning: Bool = false
    // 放弃确认弹窗
    @State private var showGiveUpConfirm = false
    // Toast 提示
    @State private var toastMessage: String?

    /// 宠物是否犯困（专注过半后 idle → sleepy）
    private var petSleepy: Bool {
        isRunning && Double(remainingSeconds) < Double(totalSeconds) * 0.5
    }

    /// 圆环进度（0 ~ 1，随时间减少逐渐画满）
    private var progress: Double {
        guard totalSeconds > 0 else { return 0 }
        return Double(totalSeconds - remainingSeconds) / Double(totalSeconds)
    }

    /// 剩余时间文本 "mm:ss"
    private var timeText: String {
        String(format: "%02d:%02d", remainingSeconds / 60, remainingSeconds % 60)
    }

    var body: some View {
        ZStack {
            // 柔和渐变背景：玻璃卡透出背景色
            LinearGradient(colors: PagePalette.focus, startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 16) {
                    headerBar      // 大标题 + 副标题
                    ringCard       // 圆环倒计时
                    petCompanion   // 宠物陪伴
                    controlCard    // 时长选择 / 开始 / 放弃
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 24)
            }
        }
        .overlay(alignment: .bottom) { toastOverlay }
        // 每秒心跳：运行中递减剩余秒数，归零即完成
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            guard isRunning else { return }
            if remainingSeconds > 1 {
                remainingSeconds -= 1
            } else {
                completeFocus()
            }
        }
    }

    // MARK: - 顶部大标题
    private var headerBar: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("专注")
                .font(.title)
                .fontWeight(.bold)
            Text("保持节奏，专注也有奖励")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 圆环倒计时卡
    private var ringCard: some View {
        GlassCard {
            VStack(spacing: 16) {
                ZStack {
                    // 底环
                    Circle()
                        .stroke(Color.indigo.opacity(0.12), lineWidth: 14)
                    // 进度环
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(
                            AngularGradient(colors: [Color.indigo, Color.purple], center: .center),
                            style: StrokeStyle(lineWidth: 14, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 1), value: remainingSeconds)
                    // 中心文字
                    VStack(spacing: 4) {
                        Text(timeText)
                            .font(.system(size: 44, weight: .heavy, design: .rounded))
                            .monospacedDigit()
                            .foregroundColor(.primary)
                        Text(isRunning ? (petSleepy ? "宠物快睡着啦…" : "专注中…") : "选好时长开始吧")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .frame(width: 230, height: 230)

                // 完成奖励说明
                Text("完成奖励：+15 EXP · +2 食物 🍙")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - 宠物陪伴（随时间从 idle 变 sleepy）
    private var petCompanion: some View {
        GlassCard(padding: 12) {
            HStack(spacing: 14) {
                PetAnimationView(
                    action: petSleepy ? "sleepy" : "idle",
                    charId: dataManager.charId,
                    speed: dataManager.animSpeed,
                    size: 64,
                    loop: true
                )
                .id("focus-pet-\(petSleepy)-\(dataManager.charId)-\(dataManager.animSpeed)")

                VStack(alignment: .leading, spacing: 4) {
                    Text(dataManager.petName)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    Text(petCompanionText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
        }
        // 未开始时不显示宠物陪伴，页面更聚焦
        .opacity(isRunning ? 1 : 0.85)
    }

    private var petCompanionText: String {
        if !isRunning {
            return "准备好了就点开始，我陪你！"
        }
        if petSleepy {
            return "zzz…主人真专注，我眯一会儿"
        }
        return "加油，还剩 \(timeText)，一起坚持！"
    }

    // MARK: - 控制卡（时长选择 / 开始 / 放弃）
    private var controlCard: some View {
        GlassCard {
            VStack(spacing: 14) {
                if isRunning {
                    // 运行中：显示放弃按钮（需二次确认）
                    Button {
                        showGiveUpConfirm = true
                    } label: {
                        HStack {
                            Image(systemName: "stop.fill")
                            Text("放弃专注")
                        }
                        .font(.body)
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.red.opacity(0.12))
                        .foregroundColor(.red)
                        .cornerRadius(12)
                    }
                } else {
                    // 未开始：时长选择 chips
                    HStack(spacing: 10) {
                        ForEach(durationOptions, id: \.self) { minutes in
                            durationChip(minutes)
                        }
                    }

                    // 开始按钮
                    Button {
                        startFocus()
                    } label: {
                        HStack {
                            Image(systemName: "play.fill")
                            Text("开始专注 \(selectedMinutes) 分钟")
                        }
                        .font(.headline)
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            LinearGradient(colors: [Color.indigo, Color.purple],
                                           startPoint: .leading, endPoint: .trailing)
                        )
                        .foregroundColor(.white)
                        .cornerRadius(14)
                    }
                }
            }
        }
        // 放弃确认：确认后本次无奖励
        .confirmationDialog("确定要放弃这次专注吗？", isPresented: $showGiveUpConfirm, titleVisibility: .visible) {
            Button("放弃专注", role: .destructive) {
                giveUpFocus()
            }
            Button("继续专注", role: .cancel) {}
        } message: {
            Text("放弃后本次专注将不会获得 EXP 和食物奖励。")
        }
    }

    /// 时长选择 chip
    private func durationChip(_ minutes: Int) -> some View {
        let isSelected = selectedMinutes == minutes
        return Button {
            selectedMinutes = minutes
            totalSeconds = minutes * 60
            remainingSeconds = minutes * 60
        } label: {
            Text("\(minutes) 分钟")
                .font(.subheadline)
                .fontWeight(isSelected ? .semibold : .regular)
                .foregroundColor(isSelected ? .white : .primary)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(isSelected ? Color.indigo : Color.indigo.opacity(0.1))
                .cornerRadius(10)
        }
        .buttonStyle(.plain)
    }

    // MARK: - 专注逻辑
    private func startFocus() {
        totalSeconds = selectedMinutes * 60
        remainingSeconds = totalSeconds
        isRunning = true
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// 专注完成：+2 食物 +15 EXP，记录今日完成，触觉庆祝 + toast
    private func completeFocus() {
        isRunning = false
        remainingSeconds = totalSeconds

        // 记录每日任务完成状态（FeedView 联动）
        dataManager.setLastFocusDate(Date())
        // 奖励：+2 食物 +8 心情，宠物开心
        var s = dataManager.loadState()
        s.pet.food += 2
        s.pet.mood = min(100, s.pet.mood + 8)
        s.pet.currentAction = "happy"
        dataManager.saveState(s)

        // 成功触觉庆祝
        UINotificationFeedbackGenerator().notificationOccurred(.success)

        // 专注完成 +15 EXP（升级则弹升级 toast）
        let leveled = dataManager.addEXP(15)
        showToast(leveled ? "🎉 宠物升到 Lv.\(dataManager.petLevel)！" : "专注完成！+15 EXP +2 食物 🎉")
    }

    /// 中途放弃：重置计时，无奖励
    private func giveUpFocus() {
        isRunning = false
        remainingSeconds = totalSeconds
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        showToast("已放弃本次专注，下次再接再厉 💪")
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
}
