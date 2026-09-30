// MARK: - 对话记录持久化（Muse 式"记录"侧栏）
// 端侧引擎历史只在内存（KEEP_ROUNDS=6，控制 token），对话记录侧栏需要跨启动留痕：
// Documents JSON 单文件存储，上限 30 个会话 × 80 条消息（超出丢最旧）。
// 服务器模式的对话同样落这里（侧栏统一视图）；续聊上下文由服务器自己管理，
// 点开旧会话只重建界面，下一句仍接着服务器当前上下文聊。
import Foundation
import SwiftUI

struct ArchivedMessage: Codable {
    var role: String   // user / assistant
    var text: String
}

struct ArchivedChatSession: Codable, Identifiable {
    let id: UUID
    var title: String
    var updatedAt: Date
    var messages: [ArchivedMessage]
}

enum AgentChatArchive {
    private static let maxSessions = 30
    private static let maxMessagesPerSession = 80
    private static var cache: [ArchivedChatSession]?

    private static var fileURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("agent_chat_history.json")
    }

    static func loadAll() -> [ArchivedChatSession] {
        if let cache { return cache }
        guard let data = try? Data(contentsOf: fileURL),
              let items = try? JSONDecoder().decode([ArchivedChatSession].self, from: data) else {
            cache = []
            return []
        }
        cache = items
        return items
    }

    /// 追加一条消息（引擎每轮 user 发送 / assistant 最终回答时调用）。
    /// 会话不存在则创建（标题取第一句用户消息），最近的会话排最前。
    static func record(sessionID: UUID, role: String, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var sessions = loadAll()
        if let idx = sessions.firstIndex(where: { $0.id == sessionID }) {
            sessions[idx].messages.append(ArchivedMessage(role: role, text: trimmed))
            if sessions[idx].messages.count > maxMessagesPerSession {
                sessions[idx].messages = Array(sessions[idx].messages.suffix(maxMessagesPerSession))
            }
            if role == "user" && sessions[idx].title.isEmpty {
                sessions[idx].title = String(trimmed.prefix(24))
            }
            sessions[idx].updatedAt = Date()
            sessions.swapAt(0, idx)   // 刚聊过的挪到最前（idx 只会是 0 或已有位置）
        } else {
            sessions.insert(ArchivedChatSession(
                id: sessionID,
                title: String(trimmed.prefix(24)),
                updatedAt: Date(),
                messages: [ArchivedMessage(role: role, text: trimmed)]), at: 0)
        }
        if sessions.count > maxSessions { sessions = Array(sessions.prefix(maxSessions)) }
        persist(sessions)
    }

    static func loadSession(id: UUID) -> ArchivedChatSession? {
        loadAll().first { $0.id == id }
    }

    static func delete(id: UUID) {
        var sessions = loadAll()
        sessions.removeAll { $0.id == id }
        persist(sessions)
    }

    private static func persist(_ sessions: [ArchivedChatSession]) {
        cache = sessions
        if let data = try? JSONEncoder().encode(sessions) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}

// MARK: - 对话记录侧栏（聊天页左上三条杠；按 今天/昨天/更早 分组，左滑删除）
struct AgentChatHistoryView: View {
    /// 点击某条记录 → 聊天页恢复该会话
    let onSelect: (ArchivedChatSession) -> Void
    @State private var sessions: [ArchivedChatSession] = []
    @Environment(\.dismiss) private var dismiss

    /// 分组模型（元组不能当 ForEach 的 id keyPath，用小结构体最稳）
    private struct ChatGroup: Identifiable {
        let id: String
        let items: [ArchivedChatSession]
    }

    init(onSelect: @escaping (ArchivedChatSession) -> Void) {
        self.onSelect = onSelect
    }

    var body: some View {
        Group {
            if sessions.isEmpty {
                VStack(spacing: 8) {
                    Text("🐾").font(.largeTitle)
                    Text("还没有聊天记录").font(.footnote).foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(grouped) { group in
                        Section(group.id) {
                            ForEach(group.items) { session in
                                Button {
                                    onSelect(session)
                                    dismiss()
                                } label: {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(session.title.isEmpty ? "（无标题对话）" : session.title)
                                            .font(.subheadline)
                                            .foregroundColor(.primary)
                                            .lineLimit(1)
                                        Text("\(session.messages.count) 条 · \(timeText(session.updatedAt))")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                            .onDelete { offsets in
                                for offset in offsets {
                                    AgentChatArchive.delete(id: group.items[offset].id)
                                }
                                sessions = AgentChatArchive.loadAll()
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("对话记录")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { sessions = AgentChatArchive.loadAll() }
    }

    /// 按 今天/昨天/更早 分组（保持最近在前）
    private var grouped: [ChatGroup] {
        let cal = Calendar.current
        var today: [ArchivedChatSession] = []
        var yesterday: [ArchivedChatSession] = []
        var earlier: [ArchivedChatSession] = []
        for s in sessions {
            if cal.isDateInToday(s.updatedAt) { today.append(s) }
            else if cal.isDateInYesterday(s.updatedAt) { yesterday.append(s) }
            else { earlier.append(s) }
        }
        var groups: [ChatGroup] = []
        if !today.isEmpty { groups.append(ChatGroup(id: "今天", items: today)) }
        if !yesterday.isEmpty { groups.append(ChatGroup(id: "昨天", items: yesterday)) }
        if !earlier.isEmpty { groups.append(ChatGroup(id: "更早", items: earlier)) }
        return groups
    }

    private func timeText(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        if Calendar.current.isDateInToday(date) {
            f.dateFormat = "HH:mm"
        } else {
            f.dateFormat = "M/d HH:mm"
        }
        return f.string(from: date)
    }
}
