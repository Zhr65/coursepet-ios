// MARK: - 专注 tab v2（多任务卡片 + 灵动岛计时 + 设置 + 数据统计）
// 列表态：任务卡片（渐变底 + 今日进度环 + 开始按钮）→ 添加/编辑任务 → 统计卡（累计/今日/分布饼图）
// 计时态：圆环倒计时 + 宠物陪伴 + 暂停/放弃；开始即上灵动岛（FocusActivityManager）
// 参考：图一任务卡 / 图二专注设置 / 图三数据统计
import SwiftUI
import AudioToolbox

struct FocusView: View {
    @EnvironmentObject var dataManager: DataManager
    @StateObject private var store = FocusStore.shared

    // ── 计时状态 ──
    @State private var activeTask: FocusTask?       // 正在专注的任务（nil=列表态）
    @State private var goalSeconds: Int = 0         // 本次目标秒数
    @State private var endAt: Date = Date()         // 结束时刻（切后台也准确）
    @State private var pausedRemaining: Int?        // 非nil=暂停中（值为剩余秒）
    @State private var isResting = false            // 休息中（完成后自动进入）
    @State private var restEndAt: Date = Date()
    // ── 弹层 / 提示 ──
    @State private var showGiveUpConfirm = false
    @State private var editSheetTask: FocusTask?    // 编辑模式；与添加共用 sheet
    @State private var showAddSheet = false
    @State private var showSettingsSheet = false
    @State private var toastMessage: String?
    // ── 统计 ──
    @State private var statsRange: FocusStatsRange = .day
    /// 每秒心跳（驱动倒计时/进度刷新）
    @State private var now = Date()

    var body: some View {
        ZStack {
            LinearGradient(colors: PagePalette.focus, startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()

            Group {
                if isResting {
                    restingView
                } else if activeTask != nil {
                    timerView
                } else {
                    taskListView
                }
            }
        }
        .overlay(alignment: .bottom) { toastOverlay }
        // 心跳
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { t in
            now = t
            tick()
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

    // MARK: - 心跳推进
    private func tick() {
        // 专注计时
        if activeTask != nil, pausedRemaining == nil, now >= endAt {
            completeFocus()
        }
        // 休息计时
        if isResting, now >= restEndAt {
            finishRest()
        }
    }

    // MARK: - 列表态
    private var taskListView: some View {
        ScrollView {
            VStack(spacing: 14) {
                headerBar            // 标题 + 设置齿轮
                ForEach(store.tasks) { task in
                    TaskCard(
                        task: task,
                        todayMinutes: store.todayMinutes(for: task, now: now),
                        onStart: { startFocus(task) },
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

    private var headerBar: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("专注")
                    .font(.title)
                    .fontWeight(.bold)
                Text("选个任务开始，宠物陪你一起 🐾")
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

    // MARK: - 计时态
    private var remainingSeconds: Int {
        guard let task = activeTask else { return 0 }
        if let paused = pausedRemaining { return paused }
        return max(0, Int(endAt.timeIntervalSince(now)))
    }

    private var elapsedSeconds: Int {
        max(0, goalSeconds - remainingSeconds)
    }

    private var timerProgress: Double {
        guard goalSeconds > 0 else { return 0 }
        return Double(elapsedSeconds) / Double(goalSeconds)
    }

    private var timeText: String {
        let s = max(0, remainingSeconds)
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    private var petSleepy: Bool {
        timerProgress > 0.5
    }

    private var timerView: some View {
        ScrollView {
            VStack(spacing: 16) {
                // 任务名横条
                if let task = activeTask {
                    HStack(spacing: 8) {
                        Circle().fill(FocusPalette.colors(task.colorIndex).0).frame(width: 10, height: 10)
                        Text(task.name)
                            .font(.headline)
                            .fontWeight(.semibold)
                        Spacer()
                        Text("今日 \(store.todayMinutes(for: task, now: now))/\(task.dailyGoalMinutes) 分钟")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.top, 8)
                }

                ringCard            // 圆环倒计时
                petCompanion        // 宠物陪伴
                timerControls       // 暂停/放弃
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
    }

    private var ringCard: some View {
        GlassCard {
            VStack(spacing: 14) {
                ZStack {
                    Circle().stroke(Color.indigo.opacity(0.12), lineWidth: 14)
                    Circle()
                        .trim(from: 0, to: timerProgress)
                        .stroke(
                            AngularGradient(colors: [Color.indigo, Color.purple], center: .center),
                            style: StrokeStyle(lineWidth: 14, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 0.5), value: remainingSeconds)
                    VStack(spacing: 4) {
                        Text(timeText)
                            .font(.system(size: 44, weight: .heavy, design: .rounded))
                            .monospacedDigit()
                            .foregroundColor(.primary)
                        Text(statusText)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .frame(width: 230, height: 230)
                Text("灵动岛正在显示倒计时 · 完成 +15 EXP +2 🍙")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var statusText: String {
        if pausedRemaining != nil { return "已暂停" }
        return petSleepy ? "宠物快睡着啦…" : "专注中…"
    }

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
                    Text(pausedRemaining != nil ? "休息一下也没关系，我等你" : "加油，我陪着你！")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
        }
    }

    private var timerControls: some View {
        HStack(spacing: 12) {
            // 暂停 / 继续
            Button {
                togglePause()
            } label: {
                HStack {
                    Image(systemName: pausedRemaining != nil ? "play.fill" : "pause.fill")
                    Text(pausedRemaining != nil ? "继续" : "暂停")
                }
                .font(.body)
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(Color.indigo.opacity(0.12))
                .foregroundColor(.indigo)
                .cornerRadius(12)
            }
            // 放弃
            Button {
                showGiveUpConfirm = true
            } label: {
                HStack {
                    Image(systemName: "stop.fill")
                    Text("放弃")
                }
                .font(.body)
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(Color.red.opacity(0.12))
                .foregroundColor(.red)
                .cornerRadius(12)
            }
        }
        .confirmationDialog("确定要放弃这次专注吗？", isPresented: $showGiveUpConfirm, titleVisibility: .visible) {
            Button("放弃专注", role: .destructive) { giveUpFocus() }
            Button("继续专注", role: .cancel) {}
        } message: {
            Text("已专注的 \(elapsedSeconds / 60) 分钟会记入统计，但本次不获得奖励。")
        }
    }

    // MARK: - 休息态
    private var restRemaining: Int { max(0, Int(restEndAt.timeIntervalSince(now))) }

    private var restingView: some View {
        VStack(spacing: 18) {
            Spacer()
            ZStack {
                Circle().stroke(Color.green.opacity(0.15), lineWidth: 14)
                Circle()
                    .trim(from: 0, to: store.settings.breakMinutes > 0
                          ? Double(restRemaining) / Double(store.settings.breakMinutes * 60) : 0)
                    .stroke(Color.green, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 4) {
                    Text("☕️")
                        .font(.system(size: 36))
                    Text("休息 \(restRemaining / 60):\(String(format: "%02d", restRemaining % 60))")
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .monospacedDigit()
                }
            }
            .frame(width: 200, height: 200)
            Text("奖励已到账，休息一下再战！")
                .font(.subheadline)
                .foregroundColor(.secondary)
            Button {
                finishRest()
            } label: {
                Text("跳过休息")
                    .font(.body)
                    .fontWeight(.semibold)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 12)
                    .background(Color.green.opacity(0.15))
                    .foregroundColor(.green)
                    .cornerRadius(12)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
    }

    // MARK: - 统计区（参考图三）
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
                statItem(value: "\(s.count)", label: "次数")
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
                statItem(value: "\(s.count)", label: "次数")
                statItem(value: formatHoursMinutes(s.minutes), label: "时长", highlight: true)
                statItem(value: "\(s.giveUps)", label: "放弃次数")
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

    // MARK: - 专注流程
    private func startFocus(_ task: FocusTask) {
        activeTask = task
        // 单次番茄默认 25 分钟；目标 ≤ 25 分钟的任务直接用目标做单次时长
        goalSeconds = min(task.dailyGoalMinutes, 25) * 60
        endAt = Date().addingTimeInterval(Double(goalSeconds))
        pausedRemaining = nil
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        FocusActivityManager.start(task: task, goalSeconds: goalSeconds)
    }

    private func togglePause() {
        if pausedRemaining == nil {
            pausedRemaining = remainingSeconds
            FocusActivityManager.pause(remainingSeconds: remainingSeconds)
        } else {
            endAt = Date().addingTimeInterval(Double(pausedRemaining ?? 0))
            FocusActivityManager.resume(remainingSeconds: pausedRemaining ?? 0)
            pausedRemaining = nil
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// 完成：记录 + 奖励 + 进休息
    private func completeFocus() {
        guard let task = activeTask else { return }
        recordSession(task: task, seconds: goalSeconds, completed: true)
        FocusActivityManager.end()

        dataManager.setLastFocusDate(Date())
        var s = dataManager.loadState()
        s.pet.food += 2
        s.pet.mood = min(100, s.pet.mood + 8)
        s.pet.currentAction = "happy"
        dataManager.saveState(s)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        let leveled = dataManager.addEXP(15)
        showToast(leveled ? "🎉 宠物升到 Lv.\(dataManager.petLevel)！" : "专注完成！+15 EXP +2 食物 🎉")
        if store.settings.completionSound {
            AudioServicesPlaySystemSound(1025)
        }

        // 进入休息
        activeTask = nil
        if store.settings.breakMinutes > 0 {
            isResting = true
            restEndAt = Date().addingTimeInterval(Double(store.settings.breakMinutes * 60))
        }
    }

    /// 放弃：记录已专注部分（不计奖励）
    private func giveUpFocus() {
        guard let task = activeTask else { return }
        let elapsed = elapsedSeconds   // 先取值，清空 activeTask 后 elapsedSeconds 会失真
        recordSession(task: task, seconds: elapsed, completed: false)
        FocusActivityManager.end()
        activeTask = nil
        pausedRemaining = nil
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        showToast("已放弃，已专注 \(elapsed / 60) 分钟记入统计 💪")
    }

    private func finishRest() {
        isResting = false
        showToast("休息结束，继续加油！")
    }

    private func recordSession(task: FocusTask, seconds: Int, completed: Bool) {
        store.addSession(FocusSession(
            taskId: task.id,
            taskName: task.name,
            colorIndex: task.colorIndex,
            start: Date().addingTimeInterval(-Double(seconds)),
            durationSeconds: seconds,
            completed: completed
        ))
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

// MARK: - 任务卡片（仿图一：渐变底 + 名称 + 目标 + 今日进度环 + 开始）
private struct TaskCard: View {
    let task: FocusTask
    let todayMinutes: Int
    let onStart: () -> Void
    let onEdit: () -> Void

    private var progress: Double {
        guard task.dailyGoalMinutes > 0 else { return 0 }
        return min(1, Double(todayMinutes) / Double(task.dailyGoalMinutes))
    }

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
                    HStack(spacing: 6) {
                        Text("\(task.dailyGoalMinutes) 分钟目标")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.9))
                        // 小进度环
                        ZStack {
                            Circle().stroke(Color.white.opacity(0.35), lineWidth: 3)
                            Circle()
                                .trim(from: 0, to: progress)
                                .stroke(Color.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                            Text("\(Int(progress * 100))%")
                                .font(.system(size: 7, weight: .bold))
                                .foregroundColor(.white)
                        }
                        .frame(width: 24, height: 24)
                        Text("今日 \(todayMinutes)/\(task.dailyGoalMinutes) 分钟")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.9))
                    }
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
                // 编辑菜单（调整目标 / 删除）
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

// MARK: - 饼图（Canvas 自绘，iOS16 无 SectorMark）
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
            // 中心留白圈（甜甜圈风格，配图三）
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

// MARK: - 添加 / 编辑任务 sheet
private struct TaskEditSheet: View {
    @EnvironmentObject var store: FocusStore
    @Environment(\.dismiss) private var dismiss
    let task: FocusTask?   // nil = 新增

    @State private var name: String = ""
    @State private var goalMinutes: Int = 60
    @State private var colorIndex: Int = 0

    var body: some View {
        NavigationStack {
            Form {
                Section("任务") {
                    TextField("任务名称（如：背单词）", text: $name)
                }
                Section("每日目标（分钟）") {
                    Stepper(value: $goalMinutes, in: 5...720, step: 5) {
                        Text("\(goalMinutes) 分钟")
                    }
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
                    goalMinutes = task.dailyGoalMinutes
                    colorIndex = task.colorIndex
                }
            }
        }
    }

    // goalMinutes 直接是 @State Int，无需转换

    private func save() {
        let cleanName = name.trimmingCharacters(in: .whitespaces)
        guard !cleanName.isEmpty else { return }
        if var task {
            task.name = cleanName
            task.dailyGoalMinutes = max(1, goalMinutes)
            task.colorIndex = colorIndex
            store.updateTask(task)
        } else {
            store.addTask(name: cleanName, goalMinutes: goalMinutes, colorIndex: colorIndex)
        }
        dismiss()
    }
}

// MARK: - 专注设置 sheet（参考图二简化版）
private struct FocusSettingsSheet: View {
    @EnvironmentObject var store: FocusStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Stepper(value: $store.settings.breakMinutes, in: 0...60, step: 5) {
                        HStack {
                            Text("休息时间")
                            Spacer()
                            Text(store.settings.breakMinutes == 0 ? "关闭" : "\(store.settings.breakMinutes) 分钟")
                                .foregroundColor(.secondary)
                        }
                    }
                    Toggle("完成后提示音", isOn: $store.settings.completionSound)
                } header: {
                    Text("专注计时")
                } footer: {
                    Text("每次完成一个番茄后自动进入休息倒计时；设置为「关闭」则直接回到任务列表。")
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
