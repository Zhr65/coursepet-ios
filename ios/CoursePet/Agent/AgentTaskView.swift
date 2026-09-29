// MARK: - 定时任务中心（Muse 式异步任务）
// 聊天里让 Agent 建任务 → 服务器后台到点自动执行 ReAct → 这里看汇报、管任务。
// 打开页面即把全部未读结果标为已读（铃铛角标清零）；删除 = 软取消（移入"已结束"）。
import SwiftUI

struct AgentTaskView: View {
    @State private var tasks: [AgentTaskData] = []
    @State private var segment = 0          // 0=进行中 1=已结束
    @State private var isLoading = false
    @State private var loadFailed = false
    @State private var serverConfigured = true

    private var visibleTasks: [AgentTaskData] {
        segment == 0 ? tasks.filter { $0.status == "active" }
                     : tasks.filter { $0.status != "active" }
    }

    var body: some View {
        List {
            Section {
                Picker("分段", selection: $segment) {
                    Text("进行中").tag(0)
                    Text("已结束").tag(1)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
            }

            if !serverConfigured {
                Section {
                    Text("定时任务需要开启服务器模式（设置页填写服务器三件套）。\n端侧模式下创建的任务是本地提醒，到点弹通知。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            } else if isLoading && tasks.isEmpty {
                Section {
                    HStack { Spacer(); ProgressView(); Spacer() }
                }
            } else if loadFailed {
                Section {
                    Text("加载失败，检查网络后下拉重试")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            } else if visibleTasks.isEmpty {
                Section {
                    Text(segment == 0
                         ? "还没有进行中的任务。在聊天里说「每天早上8点帮我看课表」就能创建一个。"
                         : "已执行完或已取消的任务会出现在这里。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }

            ForEach(visibleTasks, id: \.id) { task in
                Section {
                    if task.results.isEmpty {
                        Text("还没有执行记录，到点自动跑完会出现在这里。")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                    ForEach(task.results, id: \.id) { result in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(result.content)
                                .font(.subheadline)
                            Text(Self.timeText(result.createdAt))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    taskHeader(task)
                }
            }
        }
        .navigationTitle("定时任务")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load(markRead: true) }
        .refreshable { await load(markRead: false) }
    }

    // MARK: 任务头：标题 + 计划 + 出错提示 + 删除菜单
    @ViewBuilder
    private func taskHeader(_ task: AgentTaskData) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .font(.subheadline.weight(.semibold))
                Text(Self.scheduleText(task))
                    .font(.caption)
                    .foregroundColor(.secondary)
                if !task.lastError.isEmpty {
                    Text("上次执行出错：\(task.lastError)")
                        .font(.caption2)
                        .foregroundColor(.orange)
                }
            }
            Spacer()
            if task.status == "active" {
                Menu {
                    Button(role: .destructive) {
                        Task { await cancelTask(task) }
                    } label: {
                        Label("删除任务", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            } else {
                Text(task.status == "done" ? "已执行" : "已取消")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .textCase(nil)
    }

    // MARK: 加载任务；markRead = 打开页面时顺带把未读结果标已读（角标清零）
    private func load(markRead: Bool) async {
        let server = AgentConfigStore.loadServerConfig()
        guard server.isConfigured else {
            serverConfigured = false
            tasks = []
            loadFailed = false
            return
        }
        serverConfigured = true
        isLoading = true
        defer { isLoading = false }
        guard let fetched = try? await AgentRemoteClient.fetchAgentTasks(
            baseURL: server.baseURL,
            username: server.username,
            password: server.password) else {
            loadFailed = true
            return
        }
        loadFailed = false
        tasks = fetched
        let unreadIds = fetched.flatMap { task in
            task.results.filter { !$0.isRead }.map { $0.id }
        }
        guard markRead, !unreadIds.isEmpty else { return }
        let ok = await AgentRemoteClient.markAgentTasksRead(
            baseURL: server.baseURL, username: server.username,
            password: server.password, resultIds: unreadIds)
        if ok { NotificationManager.agentTaskUnread = 0 }
    }

    // MARK: 删除（软取消）：从当前列表移除，"已结束"下拉刷新可见
    private func cancelTask(_ task: AgentTaskData) async {
        let server = AgentConfigStore.loadServerConfig()
        guard server.isConfigured else { return }
        let ok = await AgentRemoteClient.deleteAgentTask(
            baseURL: server.baseURL, username: server.username,
            password: server.password, id: task.id)
        if ok { tasks.removeAll { $0.id == task.id } }
    }

    // MARK: 展示格式化
    /// 计划描述：daily → "每天 HH:MM"；once → "执行时刻 M月d日 HH:mm"
    private static func scheduleText(_ task: AgentTaskData) -> String {
        if task.scheduleKind == "once" {
            return task.runAt.isEmpty ? "一次性任务" : "执行时刻 " + parseTime(task.runAt, offsetHours: 0)
        }
        return task.runTime.isEmpty ? "每天定时" : "每天 \(task.runTime)"
    }

    /// 结果时间：createdAt 为 UTC → +8h 换算北京时间展示
    private static func timeText(_ createdAt: String) -> String {
        parseTime(createdAt, offsetHours: 8)
    }

    /// 服务器时间字符串（"yyyy-MM-dd HH:mm" / ISO）→ "M月d日 HH:mm"
    private static func parseTime(_ raw: String, offsetHours: Int) -> String {
        let head = String(raw.replacingOccurrences(of: "T", with: " ").prefix(16))
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        guard let date = f.date(from: head) else { return head }
        let out = DateFormatter()
        out.dateFormat = "M月d日 HH:mm"
        return out.string(from: date.addingTimeInterval(Double(offsetHours) * 3600))
    }
}
