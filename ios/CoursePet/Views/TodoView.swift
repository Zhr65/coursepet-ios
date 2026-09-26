// MARK: - 事务视图（作业 / 快递 / 记账 三分段）
// 作业列表分「待完成 / 已完成（折叠）」两个区，完成作业会给宠物奖励（+1 食物 +5 心情 +8 EXP）
// 快递与记账分区在 TransactionSections.swift 中实现，这里负责挂载
import SwiftUI

struct TodoView: View {
    @EnvironmentObject var dataManager: DataManager

    // ── 事务分段 ──
    private enum Segment {
        case homework   // 作业
        case parcel     // 快递取件
        case ledger     // 极简记账
    }
    @State private var segment: Segment = .homework

    // 添加作业弹层
    @State private var showAddSheet = false
    // 已完成区是否展开
    @State private var showCompleted = false
    // Toast 提示
    @State private var toastMessage: String?

    /// 待完成：DDL 智能排序——逾期最前（越早逾期越靠前）→ 今天 → 未来按日期 → 无日期最后
    private var pendingItems: [HomeworkItem] {
        dataManager.homeworks.filter { !$0.isDone }.sorted { a, b in
            switch (a.dueDate, b.dueDate) {
            case let (l?, r?):
                if dayRank(l) != dayRank(r) { return dayRank(l) < dayRank(r) }
                return l < r
            case (_?, nil):     return true    // 有日期在前
            default:            return false
            }
        }
    }

    /// 日期相对今天的天数偏移（负=逾期，0=今天，正=未来）
    private func dayRank(_ date: Date) -> Int {
        let calendar = Calendar.current
        return calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: Date()),
            to: calendar.startOfDay(for: date)
        ).day ?? 0
    }

    /// 已完成
    private var doneItems: [HomeworkItem] {
        dataManager.homeworks.filter { $0.isDone }
    }

    /// 今日到期数量（未完成中）
    private var todayDueCount: Int {
        pendingItems.filter { $0.dueDate != nil && Calendar.current.isDateInToday($0.dueDate!) }.count
    }

    var body: some View {
        NavigationStack {
            ZStack {
                // 柔和渐变背景：玻璃行透出背景色
                LinearGradient(colors: PagePalette.todo, startPoint: .topLeading, endPoint: .bottomTrailing)
                    .ignoresSafeArea()

                // 分段切换：作业列表 / 快递取件 / 极简记账
                switch segment {
                case .homework: homeworkList
                case .parcel:   ParcelSection()
                case .ledger:   LedgerSection()
                }
            }
            .navigationTitle("")
            .toolbar {
                // 顶部三分段切换器（居中）
                ToolbarItem(placement: .principal) {
                    Picker("事务分段", selection: $segment) {
                        Text("作业").tag(Segment.homework)
                        Text("快递").tag(Segment.parcel)
                        Text("记账").tag(Segment.ledger)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 220)
                }
                // 添加按钮仅作业分段显示（快递/记账各有自己的入口按钮）；
                // 条件放在 ToolbarItem 内容里（外层条件在 iOS 16 上偶发不刷新）
                ToolbarItem(placement: .navigationBarTrailing) {
                    if segment == .homework {
                        Button {
                            showAddSheet = true
                        } label: {
                            Label("添加作业", systemImage: "plus")
                        }
                    } else {
                        EmptyView()
                    }
                }
            }
            // ── 添加作业 ──
            .sheet(isPresented: $showAddSheet) {
                AddHomeworkView()
                    .environmentObject(dataManager)
            }
            .overlay(alignment: .bottom) { toastOverlay }
        }
    }

    // MARK: - 作业列表（原待办列表，分段一）
    private var homeworkList: some View {
        List {
                    // ── 顶部大标题 ──
                    Section {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("作业")
                                .font(.title)
                                .fontWeight(.bold)
                            Text("完成作业也能给宠物赚 EXP")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                        .listRowBackground(Color.clear)
                    }

                    // ── 顶部统计条 ──
                    Section {
                        HStack {
                            Label("未完成 \(pendingItems.count) 个", systemImage: "tray.full")
                            Spacer()
                            Text("今日到期 \(todayDueCount) 个")
                                .foregroundColor(todayDueCount > 0 ? .orange : .secondary)
                        }
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .glassListRow()
                    }

                    // ── 待完成 ──
                    Section("📋 待完成") {
                        if pendingItems.isEmpty {
                            Text("太棒了，没有待办作业！🎉")
                                .foregroundColor(.secondary)
                                .glassListRow()
                        }
                        ForEach(pendingItems) { item in
                            homeworkRow(item)
                        }
                    }

                    // ── 已完成（折叠） ──
                    if !doneItems.isEmpty {
                        Section {
                            DisclosureGroup(isExpanded: $showCompleted) {
                                ForEach(doneItems) { item in
                                    homeworkRow(item)
                                }
                            } label: {
                                Text("已完成（\(doneItems.count)）")
                                    .foregroundColor(.secondary)
                                    .glassListRow()
                            }
                        }
                    }
        }
        .listStyle(InsetGroupedListStyle())
        .scrollContentBackground(.hidden)
    }

    // MARK: - 单行作业
    private func homeworkRow(_ item: HomeworkItem) -> some View {
        HStack(spacing: 12) {
            // 圆形勾选按钮：点击完成 / 取消完成
            Button {
                toggleItem(item)
            } label: {
                Image(systemName: item.isDone ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundColor(item.isDone ? .green : .indigo)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 4) {
                // 标题：完成后划线置灰
                Text(item.title)
                    .font(.body)
                    .strikethrough(item.isDone, color: .secondary)
                    .foregroundColor(item.isDone ? .secondary : .primary)
                // 课程名标签（关联了课程才显示）
                if let course = item.courseName, !course.isEmpty {
                    Text(course)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.indigo.opacity(0.12))
                        .foregroundColor(.indigo)
                        .cornerRadius(4)
                }
            }

            Spacer()

            // 到期日状态
            if let due = dueInfo(for: item) {
                Text(due.text)
                    .font(.caption)
                    .foregroundColor(due.color)
            }
        }
        // 滑动删除
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                dataManager.deleteHomework(id: item.id)
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
        // 液态玻璃行背景
        .glassListRow()
    }

    // MARK: - 到期日展示信息
    private struct DueInfo {
        let text: String
        let color: Color
    }

    /// 到期日文案与颜色：今天橙 / 明后天红（快到期）/ 3-6 天橙 / 逾期灰 / 其余显示具体日期
    private func dueInfo(for item: HomeworkItem) -> DueInfo? {
        guard let due = item.dueDate else { return nil }
        let calendar = Calendar.current
        if calendar.isDateInToday(due) {
            return DueInfo(text: "今天到期", color: .orange)
        }
        if due < calendar.startOfDay(for: Date()) {
            return DueInfo(text: "已过期", color: .secondary)
        }
        switch dayRank(due) {
        case 1:      return DueInfo(text: "明天到期", color: .red)
        case 2:      return DueInfo(text: "后天到期", color: .red)
        case 3...6:  return DueInfo(text: "\(dayRank(due)) 天后到期", color: .orange)
        default:
            let formatter = DateFormatter()
            formatter.dateFormat = "M月d日"
            return DueInfo(text: formatter.string(from: due), color: .secondary)
        }
    }

    // MARK: - 勾选 / 取消勾选
    private func toggleItem(_ item: HomeworkItem) {
        let willComplete = !item.isDone
        dataManager.toggleHomework(id: item.id)
        // 只有「完成」动作才有宠物奖励
        guard willComplete else { return }

        // 宠物奖励：+1 食物 +5 心情，宠物开心
        var s = dataManager.loadState()
        s.pet.food += 1
        s.pet.mood = min(100, s.pet.mood + 5)
        s.pet.currentAction = "happy"
        s.pet.bubbleText = "宠物很开心！"
        dataManager.saveState(s)

        // 触觉反馈
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.impactOccurred()
        showToast("宠物很开心！")

        // 成就：累计完成 5 个作业
        let doneCount = dataManager.homeworks.filter { $0.isDone }.count
        if doneCount >= 5, AchievementManager.unlockIfNeeded("homework5") {
            showToast("🏆 解锁成就：作业小能手")
        }

        // 每日任务联动：完成作业 +8 EXP，升级时弹升级 toast
        if dataManager.addEXP(8) {
            showToast("🎉 宠物升到 Lv.\(dataManager.petLevel)！")
        }
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

// MARK: - 添加作业弹层
private struct AddHomeworkView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var dataManager: DataManager

    // 表单状态
    @State private var title: String = ""
    // 用索引做选择值，避免课程重名时 Picker tag 冲突；0 固定为「不关联」
    @State private var courseIndex: Int = 0
    @State private var hasDueDate: Bool = false
    @State private var dueDate: Date = Date()
    // 校验错误提示
    @State private var errorMessage: String?

    /// 课程选项：第 0 项固定为「不关联」，其后是课程列表里的课程名
    private var courseOptions: [String] {
        ["不关联"] + dataManager.courses.map { $0.name }
    }

    var body: some View {
        NavigationStack {
            Form {
                // ── 作业信息 ──
                Section("📝 作业信息") {
                    TextField("作业标题（必填）", text: $title)
                    Picker("关联课程", selection: $courseIndex) {
                        ForEach(courseOptions.indices, id: \.self) { index in
                            Text(courseOptions[index]).tag(index)
                        }
                    }
                }

                // ── 到期时间 ──
                Section("⏰ 到期时间") {
                    Toggle("设置到期日期", isOn: $hasDueDate)
                    if hasDueDate {
                        DatePicker("到期日期", selection: $dueDate, displayedComponents: .date)
                    }
                }

                // ── 错误提示 ──
                if let message = errorMessage {
                    Section {
                        Text(message)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }

                // ── 保存 ──
                Section {
                    Button {
                        saveHomework()
                    } label: {
                        Text("保存作业")
                            .font(.headline)
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                            .foregroundColor(.indigo)
                    }
                }
            }
            .navigationTitle("添加作业")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }

    // MARK: - 保存
    private func saveHomework() {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        // 校验：标题必填
        guard !trimmed.isEmpty else {
            errorMessage = "请填写作业标题"
            return
        }
        errorMessage = nil

        let item = HomeworkItem(
            title: trimmed,
            courseName: courseIndex == 0 ? nil : courseOptions[courseIndex],
            dueDate: hasDueDate ? Calendar.current.startOfDay(for: dueDate) : nil
        )
        dataManager.addHomework(item)
        dismiss()
    }
}
