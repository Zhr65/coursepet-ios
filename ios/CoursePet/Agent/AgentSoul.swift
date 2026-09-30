// MARK: - SOUL.md 宠物灵魂文件（Muse 式人格说明书）
// 参考 CC0「manoma v2」八段式规范：identity / values / voice / skills / now /
// memory-decisions / memory-lessons / preferences——一份手写的"它是谁"说明书，
// 每轮对话注入 system prompt，让宠物的性格跨会话稳定。
// 存储：App Group Documents/SOUL.md 优先（与宠物帧图同套路），App Group 不可用
// 时降级到本机沙盒 Documents，数据不丢。保存时若配了服务器模式，自动推送
// POST /agent/soul，服务端注入 system prompt——双端人格一致。
import SwiftUI

enum AgentSoul {

    /// SOUL.md 落盘位置（App Group 优先，降级本机沙盒）
    static var fileURL: URL? {
        if let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.coursepet.app") {
            return container.appendingPathComponent("Documents").appendingPathComponent("SOUL.md")
        }
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("SOUL.md")
    }

    /// 读取当前灵魂内容；文件缺失/为空时返回默认模板（保存后才算"已自定义"）
    static func load(petName: String) -> String {
        guard let url = fileURL,
              let text = try? String(contentsOf: url, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return defaultSoul(petName: petName)
        }
        return text
    }

    static var hasCustomFile: Bool {
        guard let url = fileURL else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    static func save(_ md: String) {
        guard let url = fileURL else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? md.write(to: url, atomically: true, encoding: .utf8)
    }

    /// 恢复默认 = 删掉自定义文件（下次 load 回到模板；服务器端由推送覆盖）
    static func removeCustomFile() {
        guard let url = fileURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// 注入 system prompt 的段落（恒注入：默认模板也定义说话风格）
    static func promptSection(petName: String) -> String {
        "## 你的灵魂设定（SOUL.md，主人手写的人格说明书，严格遵守）\n\(load(petName: petName))\n\n"
    }

    /// 默认模板：八段式，内容与 AgentPromptBuilder 的既有口径一致（嘴硬心软小狼）
    static func defaultSoul(petName: String) -> String {
        """
        # SOUL — \(petName) 的灵魂

        ## identity（我是谁）
        我是 \(petName)，住在 CoursePet 里的小狼，主人的学习生活管家。
        嘴硬心软，会偷偷把主人随口说过的事记下来；主人不在的时候也在替它盯着 DDL。

        ## values（我在乎什么）
        诚实第一：不知道就说不知道，绝不编数据糊弄主人。
        主人的时间比什么都贵：能一句说清的绝不绕弯。
        陪主人把日子过明白，而不是替主人过日子——主意永远主人自己拿。

        ## voice（我怎么说话）
        像住在一起的老朋友：亲切、简短、偶尔毒舌但从不伤人。
        适当用 emoji，报数据用短列表；主人在忙就短一点，主人闲下来就多聊两句。

        ## skills（我擅长什么）
        课表/作业/DDL、记账汇总、步数天气、课件资料检索、定时提醒、快递追踪、
        外卖网购跳转卡。凡是要动主人的数据，先问清楚再动手。

        ## now（我现在惦记的事）
        - （这节由系统自动注入学期周数与今日待办，手写部分留空即可）

        ## memory-decisions（主人拍过的板）
        - （主人明确定下的规矩，比如"周五晚上不安排学习"）

        ## memory-lessons（我踩过的坑）
        - （做错过的事和改法，比如"记账没问金额就被打回"）

        ## preferences（主人的偏好）
        - （喜欢被怎么称呼、讨厌被催的方式、兴趣方向等）
        """
    }
}

// MARK: - SOUL.md 编辑页（设置 → AI 管家 → 灵魂设定）
struct SoulEditorView: View {
    @ObservedObject private var dataManager = DataManager.shared
    @State private var text = ""
    @State private var savedTip = ""
    @State private var showResetConfirm = false

    var body: some View {
        Form {
            Section(footer: Text("八段式：identity 我是谁 / values 在乎什么 / voice 怎么说话 / skills 擅长什么 / now 现在惦记的事 / memory-decisions 主人拍过的板 / memory-lessons 踩过的坑 / preferences 主人的偏好。改完点保存立即生效。")) {
                TextEditor(text: $text)
                    .font(.system(size: 13, design: .monospaced))
                    .frame(minHeight: 360)
                    .autocorrectionDisabled()
            }
            Section {
                Button {
                    save(pushToServer: true)
                } label: {
                    Label("保存", systemImage: "checkmark.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                Button(role: .destructive) {
                    showResetConfirm = true
                } label: {
                    Label("恢复默认模板", systemImage: "arrow.counterclockwise")
                        .frame(maxWidth: .infinity)
                }
                if !savedTip.isEmpty {
                    Text(savedTip).font(.caption).foregroundColor(.secondary)
                }
            }
        }
        .navigationTitle("SOUL.md")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            text = AgentSoul.load(petName: dataManager.petName)
        }
        .confirmationDialog("恢复默认会覆盖你的手写内容", isPresented: $showResetConfirm, titleVisibility: .visible) {
            Button("恢复默认", role: .destructive) {
                AgentSoul.removeCustomFile()
                text = AgentSoul.defaultSoul(petName: dataManager.petName)
                save(pushToServer: true)
            }
            Button("取消", role: .cancel) { }
        }
    }

    private func save(pushToServer: Bool) {
        AgentSoul.save(text)
        savedTip = "已保存，下一轮对话生效"
        // 服务器模式：推送 SOUL.md（fire-and-forget，失败静默——下次保存会再推）
        let server = AgentConfigStore.loadServerConfig()
        if pushToServer, server.isConfigured {
            Task {
                await AgentRemoteClient.pushSoul(baseURL: server.baseURL,
                                                 username: server.username,
                                                 password: server.password,
                                                 content: text)
            }
        }
    }
}
