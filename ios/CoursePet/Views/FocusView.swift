// MARK: - 专注 tab v3（暂停制正计时，无目标时长）
// 列表态：任务卡片（名称 + 今日累计 + 开始）→ 添加/编辑任务 → 统计卡（累计/今日/分布饼图）
// 计时态：点开始进入全屏计时页（fullScreenCover），只有「暂停」才能退出；
//         暂停 → 时间停住并保存本段，可「继续」接着累计或「结束专注」离开；
//         暂停超过设定分钟数（默认 20）发本地通知提醒；今日统计按自然日自动重置。
import SwiftUI
import AudioToolbox
import ActivityKit

struct FocusView: View {
    @EnvironmentObject var dataManager: DataManager
    @StateObject private var store = FocusStore.shared

    // ── 全屏计时页（item 非 nil 即弹出）──
    @State private var activeTask: FocusTask?
    // ── 弹层 / 提示 ──
    @State private var editSheetTask: FocusTask?    // 编辑模式；与添加共用 sheet
    @State private var showAddSheet = false
    @State private var showSettingsSheet = false
    @State private var toastMessage: String?
    // ── 统计 ──
    @State private var statsRange: FocusStatsRange = .day
    /// 每秒心跳（刷新列表里的今日时长显示）
    @State private var now = Date()

    var body: some View {
        ZStack {
            GlassBackdrop()
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 14) {
                    headerBar            // 标题 + 设置齿轮
                    ForEach(store.tasks) { task in
                        TaskCard(
                            task: task,
                            todayMinutes: store.todaySeconds(for: task, now: now) / 60,
                            onStart: { activeTask = task },
                            onEdit: {
                                editSheetTask = task
                                showAddSheet = true
                            }
                        )
                    }
                    addTaskButton
                    statsSection         // 累计 / 今日 / 分布饼图
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 24)
            }
        }
        .overlay(alignment: .bottom) { toastOverlay }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { now = $0 }
        // ── 全屏专注计时页：只有暂停才能退出 ──
        .fullScreenCover(item: $activeTask) { task in
            FocusTimerView(task: task) { message in
                activeTask = nil
                showToast(message)
            }
            .environmentObject(dataManager)
        }
        .sheet(isPresented: $showAddSheet, onDismiss: { editSheetTask = nil }) {
            TaskEditSheet(task: editSheetTask)
                .environmentObject(store)
        }
        .sheet(isPresented: $showSettingsSheet) {
            FocusSettingsSheet()
                .environmentObject(store)
        }
    }

    // MARK: - 顶部大标题 + 设置入口
    private var headerBar: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("专注")
                    .font(.title)
                    .fontWeight(.bold)
                Text("想专注多久都行，暂停随时休息 🐾")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button {
                showSettingsSheet = true
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .padding(10)
                    .background(Color.white.opacity(0.6))
                    .clipShape(Circle())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var addTaskButton: some View {
        Button {
            editSheetTask = nil
            showAddSheet = true
        } label: {
            HStack {
                Image(systemName: "plus.circle.fill")
                Text("添加专注任务")
            }
            .font(.subheadline)
            .fontWeight(.medium)
            .foregroundColor(.indigo)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Color.white.opacity(0.55))
            .cornerRadius(12)
        }
    }

    // MARK: - 统计区
    private var statsSection: some View {
        VStack(spacing: 12) {
            totalCard       // 累计专注
            todayCard       // 今日专注
            distributionCard // 专注时长分布（饼图）
        }
    }

    private var totalCard: some View {
        let s = store.totalSummary(now: now)
        return GlassCard(padding: 14) {
            HStack {
                Text("累计专注")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)
                Spacer()
                Image(systemName: "chart.bar.fill")
                    .foregroundColor(.indigo.opacity(0.6))
            }
            HStack(spacing: 0) {
                statItem(value: "\(s.count)", label: "段数")
                statItem(value: formatHoursMinutes(s.totalMinutes), label: "时长", highlight: true)
                statItem(value: formatHoursMinutes(s.dailyAvgMinutes), label: "日均时长")
            }
        }
    }

    private var todayCard: some View {
        let s = store.todaySummary(now: now)
        return GlassCard(padding: 14) {
            HStack {
                Text("今日专注")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)
                Spacer()
            }
            HStack(spacing: 0) {
                statItem(value: "\(s.count)", label: "段数")
                statItem(value: formatHoursMinutes(s.minutes), label: "时长", highlight: true)
                statItem(value: formatHoursMinutes(s.longestMinutes), label: "最长一段")
            }
        }
    }

    private var distributionCard: some View {
        let data = store.distribution(in: statsRange, now: now)
        let totalMinutes = data.reduce(0) { $0 + $1.minutes }
        return GlassCard(padding: 14) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("专注时长分布")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    Spacer()
                    Picker("区间", selection: $statsRange) {
                        ForEach(FocusStatsRange.allCases, id: \.self) { r in
                            Text(r.rawValue).tag(r)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 150)
                }

                if data.isEmpty {
                    Text("这个区间还没有专注记录")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 28)
                } else {
                    PieChartView(
                        slices: data.map { PieSlice(minutes: $0.minutes, color: FocusPalette.colors($0.colorIndex).0) }
                    )
                    .frame(height: 170)
                    Text("总计：\(formatHoursMinutes(totalMinutes))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity)
                    // 图例
                    ForEach(data, id: \.name) { d in
                        HStack(spacing: 8) {
                            Circle().fill(FocusPalette.colors(d.colorIndex).0).frame(width: 9, height: 9)
                            Text(d.name).font(.caption)
                            Spacer()
                            Text(totalMinutes > 0
                                 ? "\(Int(Double(d.minutes) / Double(totalMinutes) * 100))%"
                                 : "0%")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(formatHoursMinutes(d.minutes))
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .frame(width: 76, alignment: .trailing)
                        }
                    }
                }
            }
        }
    }

    private func statItem(value: String, label: String, highlight: Bool = false) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(highlight ? .title3.bold() : .title3)
                .monospacedDigit()
                .foregroundColor(.primary)
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    /// "964" → "16小时4分" / "42" → "42分钟"
    private func formatHoursMinutes(_ minutes: Int) -> String {
        guard minutes > 0 else { return "0分钟" }
        if minutes < 60 { return "\(minutes)分钟" }
        return "\(minutes / 60)小时\(minutes % 60)分"
    }

    // MARK: - Toast
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

// MARK: - 全屏专注计时页（只有暂停才能退出）
private struct FocusTimerView: View {
    let task: FocusTask
    let onClose: (String) -> Void           // 结束专注 → 回列表页（带回执 toast 文案）
    @EnvironmentObject var dataManager: DataManager
    @StateObject private var store = FocusStore.shared

    @State private var baseSeconds = 0      // 已暂停保存的段落累计
    @State private var segmentStart = Date()// 当前段落开始时刻
    @State private var isPaused = false
    @State private var pauseStart = Date()  // 暂停开始时刻（显示暂停多久）
    @State private var now = Date()
    // ── 岛按钮对账 + 本地剧情（A 线）──
    @State private var lastCmdEpoch = Date.distantPast // 已对账的岛命令水位（onAppear 设为起始时刻）
    @State private var tickCount = 0                   // 秒心跳计数（5 秒节流对账）
    @State private var lastStoryMilestone = 0          // 已播报的剧情里程碑（分钟）
    @State private var islandEndedOnBackground = false // CoursePetApp .background 时 end 了岛，
                                                       // 用本地 flag 记状态避免依赖 ActivityKit 列表更新延迟
    @Environment(\.scenePhase) private var scenePhase

    /// 当前累计秒数（含进行中段落）
    private var elapsed: Int {
        isPaused ? baseSeconds : baseSeconds + max(0, Int(now.timeIntervalSince(segmentStart)))
    }
    /// 已暂停的秒数
    private var pausedDuration: Int {
        isPaused ? max(0, Int(now.timeIntervalSince(pauseStart))) : 0
    }
    /// 超过 30 分钟宠物犯困
    private var petSleepy: Bool { elapsed > 30 * 60 }

    var body: some View {
        ZStack {
            GlassBackdrop()
                .ignoresSafeArea()

            VStack(spacing: 20) {
                // 任务名 + 今日累计
                VStack(spacing: 6) {
                    HStack(spacing: 8) {
                        Circle().fill(FocusPalette.colors(task.colorIndex).0).frame(width: 10, height: 10)
                        Text(task.name)
                            .font(.headline)
                            .fontWeight(.bold)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    Text("今日已专注 \(formatHM(todayTotalSeconds))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.top, 24)

                ringCard        // 正计时环
                petCompanion    // 宠物陪伴
                controls        // 暂停 / 继续 + 结束
                Spacer()
            }
            .padding(.horizontal, 20)
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { date in
            now = date
            islandTick()
        }
        .onAppear {
            // 进页面即开始计时并上灵动岛；顺便确保通知权限（暂停提醒需要）
            segmentStart = Date()
            // 只对账本次专注开始之后的岛命令（旧会话残留命令在此滤掉，首次对账时被 prune 清走）
            lastCmdEpoch = Date()
            FocusActivityManager.start(task: task, elapsedSeconds: 0)
            // 持久化进行中段落元数据：App 被杀后冷启动靠它自动结算（FocusAutoSettle）
            FocusActiveSegment.set(FocusActiveSegment.Info(
                taskId: task.id,
                taskName: task.name,
                colorIndex: task.colorIndex,
                sessionStart: Date(),
                segmentStart: segmentStart,
                paused: false,
                backgroundAt: nil
            ))
            NotificationManager.requestAuthorization()
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
        // 回前台立即对账一次：App 后台/锁屏期间岛按钮的操作在这里跟上
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .active:
                // CoursePetApp .background 时 end 了专注岛（杀掉 App = 结束专注）。
                // 如果 FocusTimerView 还活着（没杀进程只是切出去），内存里有进行中状态
                // 就用 baseSeconds/isPaused 重建岛（endAll 已清旧 Activity，start 会新建）
                if islandEndedOnBackground, FocusActiveSegment.get() != nil {
                    if isPaused {
                        FocusActivityManager.start(task: task, elapsedSeconds: baseSeconds)
                        FocusActivityManager.pause(elapsedSeconds: baseSeconds)
                    } else {
                        FocusActivityManager.start(task: task, elapsedSeconds: baseSeconds)
                    }
                    islandEndedOnBackground = false
                }
                reconcileIslandCommands()
            case .background:
                // CoursePetApp 会 end 专注岛；这里只记本地 flag
                islandEndedOnBackground = true
            default:
                break
            }
        }
    }

    // MARK: - 岛务巡检（每秒心跳）
    private func islandTick() {
        tickCount += 1
        if tickCount % 5 == 0 {
            reconcileIslandCommands()   // 5 秒节流读命令日志（UserDefaults 读是进程内缓存，开销可忽略）
        }
        if !isPaused {
            storyTickIfNeeded()
        }
    }

    /// 同步进行中段落元数据（冷启动自动结算的数据源）
    private func updateActiveSegment(paused: Bool, segmentStart: Date? = nil) {
        guard var info = FocusActiveSegment.get() else { return }
        info.paused = paused
        if let segmentStart { info.segmentStart = segmentStart }
        FocusActiveSegment.set(info)
    }

    /// 岛按钮命令对账：锁屏/灵动岛上的按钮在扩展进程改了 Activity，
    /// 这里把 App 内计时状态按命令日志重放跟上（last-writer-wins，秒级 UX 足够）
    private func reconcileIslandCommands() {
        let pending = FocusIslandCommandLog.pendingCommands(after: lastCmdEpoch)
        guard !pending.isEmpty else { return }
        for cmd in pending {
            lastCmdEpoch = max(lastCmdEpoch, cmd.epoch)
            switch cmd.action {
            case .pause where !isPaused:
                // 按岛上的操作时刻结算进行中段落（对齐 pauseTapped 的逻辑）
                let seg = max(0, Int(cmd.epoch.timeIntervalSince(segmentStart)))
                baseSeconds += seg
                isPaused = true
                pauseStart = cmd.epoch
                store.addSession(FocusSession(
                    taskId: task.id,
                    taskName: task.name,
                    colorIndex: task.colorIndex,
                    start: cmd.epoch.addingTimeInterval(-Double(seg)),
                    durationSeconds: seg,
                    completed: true
                ))
                // 暂停提醒只能 App 进程排（扩展进程发不了本地通知）：
                // App 被杀期间的岛暂停没有提醒，属可接受降级
                NotificationManager.schedulePauseReminder(afterMinutes: store.settings.pauseRemindMinutes, taskName: task.name)
                updateActiveSegment(paused: true)
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            case .resume where isPaused:
                NotificationManager.cancelPauseReminder()
                isPaused = false
                segmentStart = cmd.epoch
                updateActiveSegment(paused: false, segmentStart: cmd.epoch)
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            case .end:
                // 用岛上算出的累计值结算（比本地 baseSeconds 更准，防中途漏对账）
                finishWithReward(totalSeconds: max(baseSeconds, cmd.elapsed))
            default:
                break // 乱序/对冲命令（如已暂停又收到 pause）：last-writer-wins，丢弃
            }
        }
        FocusIslandCommandLog.prune(keepingAfter: lastCmdEpoch)
    }

    /// 本地里程碑剧情：专注满 5/10/20/30/45/60/90 分钟给岛上换一条宠物语录。
    /// 暂停中不播（岛上是"歇会儿"状态）；storyText 在下次暂停时被清空回落内置语录。
    private static let storyMilestones: [(minute: Int, text: String, action: String)] = [
        (5, "已经专注 5 分钟啦，状态不错，继续保持～", "idle"),
        (10, "10 分钟了！脑子热起来了，正是好时候", "happy"),
        (20, "专注 20 分钟，你认真的样子真好看", "happy"),
        (30, "半小时啦！喝口水，我继续陪你", "idle"),
        (45, "45 分钟，稳得很，别停下", "happy"),
        (60, "整整一小时！今天也是厉害的一天", "happy"),
        (90, "一个半小时了……你是超人吧", "happy"),
    ]

    private func storyTickIfNeeded() {
        let minute = elapsed / 60
        guard let milestone = FocusTimerView.storyMilestones
            .first(where: { minute >= $0.minute && $0.minute > lastStoryMilestone }) else { return }
        lastStoryMilestone = milestone.minute
        FocusActivityManager.updateStory(text: milestone.text, petAction: milestone.action)
    }

    /// 今日累计 = 已保存段落 + 进行中段落
    private var todayTotalSeconds: Int {
        store.todaySeconds(for: task, now: now) + (isPaused ? 0 : max(0, Int(now.timeIntervalSince(segmentStart))))
    }

    // 正计时环（60 分钟一圈循环，无目标所以环只做节奏参考）
    // 秒数显示用 TimelineView 整秒对齐驱动，替代依赖外层 onReceive tick —— 否则 tick 相位
    // 与秒边界错开时，同一秒会显示两个 tick、下一秒又跳 2（观感"不是一秒一秒变"）
    private var ringCard: some View {
        return TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let tickDate = timeline.date
            let displaySeconds = isPaused
                ? baseSeconds
                : baseSeconds + max(0, Int(tickDate.timeIntervalSince(segmentStart)))
            let progress = Double(displaySeconds % 3600) / 3600.0
            return ZStack {
                Circle().stroke(Color.indigo.opacity(0.12), lineWidth: 14)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(
                        AngularGradient(colors: [Color.indigo, Color.purple], center: .center),
                        style: StrokeStyle(lineWidth: 14, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 6) {
                    Text(timeString(displaySeconds))
                        .font(.system(size: 42, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                        .foregroundColor(.primary)
                    Text(isPaused ? "已暂停 \(timeString(pausedDuration))" : "专注中")
                        .font(.caption)
                        .foregroundColor(isPaused ? .orange : .secondary)
                }
            }
            .frame(width: 240, height: 240)
        }
    }

    private var petCompanion: some View {
        GlassCard(padding: 14) {
            HStack(spacing: 14) {
                PetAnimationView(
                    action: petSleepy ? "sleepy" : "idle",
                    charId: dataManager.charId,
                    speed: dataManager.animSpeed,
                    size: 64,
                    loop: true
                )
                .id("timer-pet-\(petSleepy)-\(dataManager.charId)-\(dataManager.animSpeed)")
                VStack(alignment: .leading, spacing: 4) {
                    Text(dataManager.petName)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    Text(isPaused ? "歇会儿，我在这儿等你～" : "加油，我陪着你！")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 12) {
            if isPaused {
                // 暂停中：继续 + 结束专注
                Button(action: resumeTapped) {
                    HStack {
                        Image(systemName: "play.fill")
                        Text("继续专注")
                    }
                    .font(.headline)
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.indigo)
                    .foregroundColor(.white)
                    .cornerRadius(14)
                }
                Button(action: endTapped) {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                        Text("结束专注")
                    }
                    .font(.body)
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(Color.red.opacity(0.12))
                    .foregroundColor(.red)
                    .cornerRadius(12)
                }
            } else {
                // 运行中：只有暂停（没有其他退出方式）
                Button(action: pauseTapped) {
                    HStack {
                        Image(systemName: "pause.fill")
                        Text("暂停")
                    }
                    .font(.headline)
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(GlassSurface(cornerRadius: 14))
                    .foregroundColor(.indigo)
                }
                Text("暂停后才能离开本页")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - 流程
    /// 暂停：保存本段 → 灵动岛停住 → 排 20 分钟提醒通知
    private func pauseTapped() {
        lastCmdEpoch = now   // 本地操作 = 最新写入，压过同期岛命令
        let seg = max(0, Int(now.timeIntervalSince(segmentStart)))
        baseSeconds += seg
        isPaused = true
        pauseStart = now
        store.addSession(FocusSession(
            taskId: task.id,
            taskName: task.name,
            colorIndex: task.colorIndex,
            start: now.addingTimeInterval(-Double(seg)),
            durationSeconds: seg,
            completed: true
        ))
        FocusActivityManager.pause(elapsedSeconds: baseSeconds)
        NotificationManager.schedulePauseReminder(afterMinutes: store.settings.pauseRemindMinutes, taskName: task.name)
        updateActiveSegment(paused: true)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// 继续：取消提醒 → 灵动岛续走
    private func resumeTapped() {
        lastCmdEpoch = now
        NotificationManager.cancelPauseReminder()
        isPaused = false
        segmentStart = now
        FocusActivityManager.resume(elapsedSeconds: baseSeconds)
        updateActiveSegment(paused: false, segmentStart: now)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// 结束专注：仅在暂停中可点（运行中没有此按钮）；最后一段已在暂停时保存
    private func endTapped() {
        guard isPaused else { return }
        lastCmdEpoch = now
        finishWithReward(totalSeconds: baseSeconds)
    }

    /// 结束收尾（App 内结束 & 岛按钮结束共用）：奖励 + 关闭计时页
    private func finishWithReward(totalSeconds: Int) {
        FocusActiveSegment.set(nil)  // 本次专注已正常结算，清掉冷启动自动结算的元数据
        FocusActivityManager.end()   // 岛按钮路径 Intent 已 end，这里幂等兜底
        NotificationManager.cancelPauseReminder()
        if store.settings.completionSound {
            AudioServicesPlaySystemSound(1025)
        }

        // 奖励：按本次累计时长给 EXP（≥1 分钟起步；每满 10 分钟 +5 EXP，上限 30）+ 食物 + 心情
        let minutes = totalSeconds / 60
        var message = "本次专注 \(minutes) 分钟，辛苦啦 ☕️"
        if minutes >= 1 {
            let reward = FocusReward.apply(minutes: minutes)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            message = reward.leveled
                ? "🎉 本次专注 \(minutes) 分钟，宠物升到 Lv.\(dataManager.petLevel)！"
                : "本次专注 \(minutes) 分钟，+\(reward.exp) EXP +2 🍙"
        }

        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        onClose(message)
    }

    // MARK: - 工具
    private func timeString(_ s: Int) -> String {
        if s >= 3600 {
            return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
        }
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
    private func formatHM(_ seconds: Int) -> String {
        let m = seconds / 60
        if m < 60 { return "\(m) 分钟" }
        return "\(m / 60) 小时 \(m % 60) 分"
    }
}

// MARK: - 专注奖励（App 内结束 & 岛按钮结束冷启动补发共用）
enum FocusReward {
    /// 按专注分钟发放奖励（+EXP/+食物/+心情），返回 (EXP, 是否升级)
    @discardableResult
    static func apply(minutes: Int) -> (exp: Int, leveled: Bool) {
        guard minutes >= 1 else { return (0, false) }
        let dm = DataManager.shared
        dm.setLastFocusDate(Date())
        var s = dm.loadState()
        s.pet.food += 2
        s.pet.mood = min(100, s.pet.mood + 8)
        s.pet.currentAction = "happy"
        dm.saveState(s)
        let exp = min(30, 5 + (minutes / 10) * 5)
        let leveled = dm.addEXP(exp)
        return (exp, leveled)
    }
}

// MARK: - 进行中专注段落元数据（冷启动自动结算用）
// 专注计时状态只存 FocusView 内存，App 被杀后"最后一段"本来会丢（只有点结束才统计）。
// 开始/暂停/继续时把段落元数据写入 UserDefaults，退后台时打点；
// 冷启动由 FocusAutoSettle.settleOnLaunch() 据此补统计 —— 补到最近一次退后台为止，
// 防止把 App 死掉期间的时间也算进专注时长。
enum FocusActiveSegment {
    struct Info: Codable {
        var taskId: String
        var taskName: String
        var colorIndex: Int
        var sessionStart: Date   // 本次专注会话开始时刻（结算"本次"奖励口径用）
        var segmentStart: Date   // 当前进行中段落开始时刻
        var paused: Bool         // 暂停中：段落已在暂停时保存，无需补统计
        var backgroundAt: Date?  // 最近一次退后台/锁屏时刻（结算终点）
    }

    private static let key = "focus.activeSegment"

    static func set(_ info: Info?) {
        if let info, let data = try? JSONEncoder().encode(info) {
            StorageLocation.defaults.set(data, forKey: key)
        } else {
            StorageLocation.defaults.removeObject(forKey: key)
        }
    }

    static func get() -> Info? {
        guard let data = StorageLocation.defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Info.self, from: data)
    }

    /// 退后台/锁屏打点：App 层 scenePhase 变化时调用（FocusTimerView 不可见的场景也能覆盖）
    static func markBackground(at date: Date = Date()) {
        guard var info = get(), !info.paused else { return }
        info.backgroundAt = date
        set(info)
    }
}

// MARK: - 冷启动自动结算
// 杀掉 App 再进：进行中那段专注自动统计（补存 session + 按本次会话总时长补奖励），
// 岛按钮点过结束的命令也在这统一补奖励 —— 行为与点「结束专注」一致。
enum FocusAutoSettle {
    @MainActor
    static func settleOnLaunch() {
        let endCommands = FocusIslandCommandLog.takeEndCommandsOnLaunch()  // 顺手清空命令日志
        guard let active = FocusActiveSegment.get() else {
            // 无元数据（异常残留）但岛上点过结束：按岛算的累计补奖励，不亏
            if let elapsed = endCommands.last?.elapsed {
                settleReward(totalMinutes: elapsed / 60)
            }
            return
        }
        FocusActiveSegment.set(nil)   // 无论哪条路径都视为结算完毕，清元数据防重复结算

        // 最后一段没走正常暂停/结束流程时补存：结算到最近一次退后台（App 死掉期间不算）
        var lastSegmentSeconds = 0
        if !active.paused {
            let end = active.backgroundAt ?? active.segmentStart
            lastSegmentSeconds = max(0, Int(end.timeIntervalSince(active.segmentStart)))
            if lastSegmentSeconds > 0 {
                FocusStore.shared.addSession(FocusSession(
                    taskId: active.taskId,
                    taskName: active.taskName,
                    colorIndex: active.colorIndex,
                    start: active.segmentStart,
                    durationSeconds: lastSegmentSeconds,
                    completed: true
                ))
            }
        }

        // 本次会话总时长 = 已保存段落总和 + 补存的最后一段（与 endTapped 的 baseSeconds 口径一致）。
        // App 死后岛上暂停过的段落可能没对账，用岛上 end 命令的累计值兜底校准奖励，不亏时长。
        let saved = FocusStore.shared.sessions
            .filter { $0.taskId == active.taskId && $0.start >= active.sessionStart.addingTimeInterval(-1) }
            .reduce(0) { $0 + $1.durationSeconds }
        let islandElapsed = endCommands.last?.elapsed ?? 0
        settleReward(totalMinutes: max((saved + lastSegmentSeconds) / 60, islandElapsed / 60))
    }

    /// 结算奖励 + 本地通知告知（结算发生在冷启动，没有 UI 可弹）
    @MainActor
    private static func settleReward(totalMinutes: Int) {
        NotificationManager.cancelPauseReminder()
        guard totalMinutes >= 1 else { return }
        let reward = FocusReward.apply(minutes: totalMinutes)
        NotificationManager.scheduleFocusSettleNotice(
            minutes: totalMinutes,
            exp: reward.exp,
            leveled: reward.leveled
        )
    }
}

// MARK: - 任务卡片（名称 + 今日累计 + 开始 + 编辑菜单）
private struct TaskCard: View {
    let task: FocusTask
    let todayMinutes: Int
    let onStart: () -> Void
    let onEdit: () -> Void

    var body: some View {
        let (c1, c2) = FocusPalette.colors(task.colorIndex)
        ZStack {
            LinearGradient(colors: [c1, c2], startPoint: .leading, endPoint: .trailing)
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(task.name)
                        .font(.headline)
                        .fontWeight(.bold)
                        .foregroundColor(.white)
                    Text(todayMinutes > 0 ? "今日 \(todayMinutes) 分钟" : "今天还没开始")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.9))
                }
                Spacer()
                Button(action: onStart) {
                    Text("开始")
                        .font(.body)
                        .fontWeight(.bold)
                        .foregroundColor(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                        .background(Color.white.opacity(0.22))
                        .cornerRadius(10)
                }
                .buttonStyle(.plain)
                // 编辑菜单（改名 / 换色 / 删除）
                Menu {
                    Button { onEdit() } label: { Label("编辑任务", systemImage: "pencil") }
                    if !task.isBuiltIn {
                        Button(role: .destructive) {
                            FocusStore.shared.removeTask(task)
                        } label: { Label("删除任务", systemImage: "trash") }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.8))
                        .padding(6)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .cornerRadius(14)
        .shadow(color: c2.opacity(0.3), radius: 6, y: 3)
    }
}

// MARK: - 饼图（Canvas 自绘甜甜圈，iOS16 无 SectorMark）
struct PieSlice {
    let minutes: Int
    let color: Color
}

struct PieChartView: View {
    let slices: [PieSlice]

    var body: some View {
        Canvas { context, size in
            let total = Double(slices.reduce(0) { $0 + $1.minutes })
            guard total > 0 else { return }
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = min(size.width, size.height) / 2 - 4
            var start = Angle.degrees(-90)
            for slice in slices {
                let frac = Double(slice.minutes) / total
                let end = start + Angle.degrees(frac * 360)
                var path = Path()
                path.move(to: center)
                path.addArc(center: center, radius: radius, startAngle: start, endAngle: end, clockwise: false)
                path.closeSubpath()
                context.fill(path, with: .color(slice.color))
                start = end
            }
            // 中心留白圈（甜甜圈风格）
            let hole = Path { p in
                p.addEllipse(in: CGRect(x: center.x - radius * 0.55, y: center.y - radius * 0.55,
                                        width: radius * 1.1, height: radius * 1.1))
            }
            context.blendMode = .clear
            context.fill(hole, with: .color(.black))
            context.blendMode = .normal
        }
        .animation(.easeInOut(duration: 0.3), value: slices.map { $0.minutes })
    }
}

// MARK: - 添加 / 编辑任务 sheet（无目标时长：名称 + 颜色）
private struct TaskEditSheet: View {
    @EnvironmentObject var store: FocusStore
    @Environment(\.dismiss) private var dismiss
    let task: FocusTask?   // nil = 新增

    @State private var name: String = ""
    @State private var colorIndex: Int = 0

    var body: some View {
        NavigationStack {
            Form {
                Section("任务") {
                    TextField("任务名称（如：背单词）", text: $name)
                }
                Section("卡片颜色") {
                    HStack(spacing: 14) {
                        ForEach(0..<FocusPalette.count, id: \.self) { i in
                            Circle()
                                .fill(FocusPalette.colors(i).0)
                                .frame(width: 34, height: 34)
                                .overlay(
                                    Circle().stroke(Color.primary, lineWidth: colorIndex == i ? 3 : 0)
                                )
                                .onTapGesture { colorIndex = i }
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                if let task, !task.isBuiltIn {
                    Section {
                        Button(role: .destructive) {
                            store.removeTask(task)
                            dismiss()
                        } label: {
                            Label("删除这个任务", systemImage: "trash")
                        }
                    }
                }
            }
            .navigationTitle(task == nil ? "添加任务" : "编辑任务")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                if let task {
                    name = task.name
                    colorIndex = task.colorIndex
                }
            }
        }
    }

    private func save() {
        let cleanName = name.trimmingCharacters(in: .whitespaces)
        guard !cleanName.isEmpty else { return }
        if var task {
            task.name = cleanName
            task.colorIndex = colorIndex
            store.updateTask(task)
        } else {
            store.addTask(name: cleanName, colorIndex: colorIndex)
        }
        dismiss()
    }
}

// MARK: - 专注设置 sheet（暂停提醒 + 提示音）
private struct FocusSettingsSheet: View {
    @EnvironmentObject var store: FocusStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Stepper(value: $store.settings.pauseRemindMinutes, in: 0...120, step: 5) {
                        HStack {
                            Text("暂停提醒")
                            Spacer()
                            Text(store.settings.pauseRemindMinutes == 0
                                 ? "关闭"
                                 : "\(store.settings.pauseRemindMinutes) 分钟")
                                .foregroundColor(.secondary)
                        }
                    }
                    Toggle("结束提示音", isOn: $store.settings.completionSound)
                } header: {
                    Text("专注")
                } footer: {
                    Text("暂停超过设定时间后发通知提醒你回来继续；设为「关闭」则不提醒。专注时长按自然日统计，每晚 12 点自动重新开始。")
                }
            }
            .navigationTitle("专注设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}
