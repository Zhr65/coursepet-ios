// MARK: - 宠物管家聊天界面
// 布局：聊天气泡列表（用户右灰 / 宠物左玻璃 / 过程标签居中小字）+ 底部输入区 + 快捷问题。
// 交互细节：思考中宠物气泡打点动画；新消息自动滚动到底部。
import SwiftUI
import PhotosUI
import UIKit

struct AgentChatView: View {
    @EnvironmentObject private var dataManager: DataManager
    @Environment(\.dismiss) private var dismiss
    @StateObject private var engine: AgentEngine
    // 语音输入（复用记账页的 SpeechLedgerController：权限申请/实时转写/清理全齐）
    @StateObject private var speech = SpeechLedgerController()
    @ObservedObject private var tts = AgentSpeech.shared

    @State private var inputText = ""
    @State private var recordPrefix = ""   // 录音前已输入的文字，识别结果拼在后面
    @State private var showLibrary = false // 课件知识库（sheet）
    @State private var taskUnread = 0    // 定时任务未读数（铃铛角标）
    @State private var showHistory = false     // 对话记录侧栏（sheet）
    @State private var showAvatarSheet = false // 更换虚拟形象（sheet）
    @State private var showFeedCenter = false  // 养成中心（push，Menu 按钮触发）
    @State private var showDiscover = false    // 兴趣动态（sheet）
    @State private var showMemory = false      // 记忆管理（sheet）
    @State private var showCall = false        // 语音通话（全屏，对标 ChatGPT 通话模式）
    @FocusState private var inputFocused: Bool

    init() {
        // 引擎需要 DataManager；EnvironmentObject 在 init 里拿不到，直接用 shared 单例
        _engine = StateObject(wrappedValue: AgentEngine(dataManager: DataManager.shared))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                chatList
                inputBar
            }
            .background(
                GlassBackdrop()
                    .ignoresSafeArea()
            )
            .navigationTitle("和\(dataManager.petName)聊聊")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // 左上三条杠：对话记录侧栏（Muse 同款入口）
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        showHistory = true
                    } label: {
                        Label("对话记录", systemImage: "line.3.horizontal")
                    }
                }
                // 顶部中央：头像 + 名字胶囊横排（Muse 同款）。
                // 竖排大图会把导航栏撑到 ~84pt 顶到灵动岛（用户实测反馈）；
                // 横排 48pt 头像仅轻微撑高导航栏，远低于翻车线，且天然水平居中。
                // 静帧：animated=false 关掉踱步镜像翻转（小尺寸下像纸片打转）
                ToolbarItem(placement: .principal) {
                    Button {
                        showAvatarSheet = true
                    } label: {
                        HStack(spacing: 8) {
                            LiveActivitySafePet(action: "happy", charId: dataManager.charId, size: 48, animated: false)
                            Text(dataManager.petName)
                                .font(.headline)
                                .fontWeight(.semibold)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 5)
                                .background(Capsule().fill(Color(.secondarySystemBackground)))
                                .foregroundColor(.primary)
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    NavigationLink {
                        AgentTaskView()
                    } label: {
                        Label("定时任务", systemImage: "bell")
                            .overlay(alignment: .topTrailing) {
                                if taskUnread > 0 {
                                    Text(taskUnread > 99 ? "99+" : "\(taskUnread)")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 2)
                                        .background(Capsule().fill(Color.red))
                                        .offset(x: 14, y: -8)
                                }
                            }
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button {
                            showLibrary = true
                        } label: {
                            Label("课件知识库", systemImage: "books.vertical")
                        }
                        Button {
                            showDiscover = true
                        } label: {
                            Label("兴趣动态", systemImage: "sparkles")
                        }
                        Button {
                            showMemory = true
                        } label: {
                            Label("记忆管理", systemImage: "brain")
                        }
                        // Menu 内 NavigationLink 在 iOS 16 可能不响应，改走 navigationDestination
                        Button {
                            showFeedCenter = true
                        } label: {
                            Label("养成中心", systemImage: "leaf")
                        }
                        Button {
                            engine.reset()
                        } label: {
                            Label("新对话", systemImage: "arrow.counterclockwise")
                        }
                    } label: {
                        Label("更多", systemImage: "ellipsis.circle")
                    }
                }
            }
            .sheet(isPresented: $showLibrary) {
                CourseLibraryView(presentedAsSheet: true)
            }
            .sheet(isPresented: $showHistory) {
                NavigationStack {
                    AgentChatHistoryView { session in
                        engine.loadSession(session)
                    }
                }
            }
            .sheet(isPresented: $showAvatarSheet) {
                PetAvatarSheet()
            }
            .navigationDestination(isPresented: $showFeedCenter) {
                FeedView()
            }
            .sheet(isPresented: $showDiscover) {
                NavigationStack { DiscoverView() }
            }
            .sheet(isPresented: $showMemory) {
                NavigationStack { MemoryManagerView() }
            }
            // 语音通话：全屏通话页，和打字共用同一个 engine（历史/归档都在一起，挂断能回看）
            .fullScreenCover(isPresented: $showCall) {
                AgentCallView(engine: engine)
                    .environmentObject(dataManager)
            }
            .onAppear {
                taskUnread = NotificationManager.agentTaskUnread
                // 定时任务结果拉取（60s 节流；服务器模式才生效）
                NotificationManager.refreshAgentTasks()
            }
            .onReceive(NotificationCenter.default.publisher(for: .agentTaskUnreadChanged)) { _ in
                taskUnread = NotificationManager.agentTaskUnread
            }
            .onDisappear {
                speech.teardown()
                tts.stop()
            }
        }
    }

    // MARK: 消息列表
    private var chatList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(engine.displayMessages) { msg in
                        bubble(for: msg)
                            .id(msg.id)
                    }
                    if engine.isThinking {
                        thinkingBubble
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 6)
            }
            .scrollDismissesKeyboard(.interactively)  // 下拉聊天时键盘跟随收起
            .onTapGesture { inputFocused = false }    // 点聊天区空白处直接收起键盘
            .onChange(of: engine.displayMessages.count) { _ in
                // 新消息到达：滚到最底
                withAnimation {
                    proxy.scrollTo(engine.displayMessages.last?.id, anchor: .bottom)
                }
                // 自动朗读：新的是 AI 回复才读；录音中跳过（音频会话冲突）
                if let last = engine.displayMessages.last,
                   case .assistant = last.kind {
                    AgentSpeech.shared.speakIfNeeded(id: last.id.uuidString, text: last.text,
                                                     suppressed: speech.isRecording)
                }
            }
        }
    }

    // MARK: 单条气泡
    @ViewBuilder
    private func bubble(for msg: ChatDisplayMessage) -> some View {
        switch msg.kind {
        case .user:
            HStack {
                Spacer(minLength: 48)
                Text(msg.text)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.blue.opacity(0.28))
                    .foregroundColor(.primary)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
            }
        case .assistant:
            // AI 长回复拆成多条短气泡（Muse 式分条）：首条带头像，末条带朗读按钮
            let segments = Self.splitBubbles(msg.text)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(segments.indices, id: \.self) { i in
                    HStack(alignment: .bottom, spacing: 8) {
                        if i == 0 {
                            // 聊天头像跟随形象商店当前形象（静帧：小尺寸下踱步动画显乱）
                            LiveActivitySafePet(action: "happy", charId: dataManager.charId, size: 30, animated: false)
                        }
                        Text(segments[i])
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(Color(.secondarySystemBackground))
                            .foregroundColor(.primary)
                            .clipShape(RoundedRectangle(cornerRadius: 18))
                        if i == segments.count - 1 {
                            // 朗读按钮：正在读这条时变成停止
                            Button {
                                tts.toggle(msg.id.uuidString, text: msg.text)
                            } label: {
                                Image(systemName: tts.speakingMessageID == msg.id.uuidString ? "stop.circle.fill" : "speaker.wave.2")
                                    .font(.caption2)
                                    .foregroundColor(tts.speakingMessageID == msg.id.uuidString ? .indigo : .secondary)
                            }
                        }
                        Spacer(minLength: 24)
                    }
                }
            }
        case .toolTrace(let label):
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.secondary.opacity(0.12))
                .clipShape(Capsule())
        case .card(let card):
            // 模式 11：Agent 产出的结构化卡片（作业/课表/账单），点击直达对应页面
            AgentCardView(card: card)
                .padding(.trailing, 24)
        case .image(let data):
            // 生图结果：宠物画好的图（1024*1024，等比缩到 240pt 圆角展示，宠物侧靠左）
            if let image = UIImage(data: data) {
                HStack(alignment: .bottom, spacing: 8) {
                    LiveActivitySafePet(action: "happy", charId: dataManager.charId, size: 30, animated: false)
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 240, height: 240)
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                        .overlay(
                            RoundedRectangle(cornerRadius: 18)
                                .stroke(Color(.separator).opacity(0.35), lineWidth: 0.5)
                        )
                    Spacer(minLength: 24)
                }
            } else {
                Text("图片显示失败了")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        case .error:
            Text(msg.text)
                .font(.footnote)
                .foregroundColor(.red)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    /// 思考中动画：三个点的透明度循环
    private var thinkingBubble: some View {
        HStack {
            // 思考中的头像同样跟随当前形象（静帧）
            LiveActivitySafePet(action: "idle", charId: dataManager.charId, size: 30, animated: false)
            TimelineView(.periodic(from: .now, by: 0.45)) { context in
                let phase = Int(context.date.timeIntervalSinceReferenceDate / 0.45) % 3
                HStack(spacing: 4) {
                    ForEach(0..<3, id: \.self) { i in
                        Circle()
                            .fill(Color.secondary)
                            .frame(width: 6, height: 6)
                            .opacity(phase == i ? 1 : 0.3)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 18))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: 输入区
    private var inputBar: some View {
        VStack(spacing: 8) {
            // 快捷问题（只在空闲时显示）
            if !engine.isThinking {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(["今天有什么课", "我有什么事没做完", "这个月花了多少"], id: \.self) { q in
                            Button(q) {
                                Task { await engine.send(q) }
                            }
                            .font(.footnote)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color(.systemIndigo).opacity(0.12))
                            .foregroundColor(.indigo)
                            .clipShape(Capsule())
                        }
                    }
                    .padding(.horizontal, 14)
                }
            }

            // 语音识别权限/启动失败提示
            if let error = speech.errorMessage {
                Text(error)
                    .font(.footnote)
                    .foregroundColor(.red)
                    .padding(.horizontal, 14)
            }
            if speech.isRecording {
                Text("正在听你说…点按钮结束")
                    .font(.caption)
                    .foregroundColor(.red)
                    .padding(.horizontal, 14)
            }

            HStack(spacing: 10) {
                // 语音通话：进"打电话"模式（口语对话、随时打断，和打字共用同一段历史）
                Button {
                    inputFocused = false
                    showCall = true
                } label: {
                    Image(systemName: "waveform.circle.fill")
                        .font(.title2)
                        .foregroundColor(.indigo)
                }
                .disabled(engine.isThinking)
                .accessibilityLabel("语音通话")

                // 语音输入：录音前先停朗读（音频会话 .record 与 .playback 互斥）
                Button {
                    if speech.isRecording {
                        speech.stopRecording()
                    } else {
                        tts.stop()
                        recordPrefix = inputText.isEmpty ? "" : inputText + " "
                        speech.startRecording()
                    }
                } label: {
                    Image(systemName: speech.isRecording ? "mic.fill" : "mic")
                        .font(.title3)
                        .foregroundColor(speech.isRecording ? .red : .indigo)
                }
                .disabled(engine.isThinking)

                TextField("和\(dataManager.petName)说点什么…", text: $inputText, axis: .vertical)
                    .lineLimit(1...4)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
                    .focused($inputFocused)
                    .onChange(of: speech.transcript) { newValue in
                        // 识别结果实时填入输入框（保留录音前已输入的文字作前缀），可编辑后再发送
                        inputText = recordPrefix + newValue
                    }
                    .onChange(of: speech.isRecording) { recording in
                        if !recording { inputFocused = true }  // 停止后聚焦，方便修改再发
                    }

                Button {
                    let text = inputText
                    inputText = ""
                    Task { await engine.send(text) }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title)
                        .foregroundColor(engine.isThinking || inputText.trimmingCharacters(in: .whitespaces).isEmpty ? .gray : .indigo)
                }
                .disabled(engine.isThinking || inputText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 8)
        }
        .padding(.top, 8)
        .background(.ultraThinMaterial)
    }
}

// MARK: - AI 长回复拆短气泡（Muse 式分条，纯展示层处理，不改引擎历史）
// 优先按换行分段；单段超 80 字按句末标点再切（每段 ~60 字）；最多 4 条，超出合并进末条。
extension AgentChatView {
    static func splitBubbles(_ text: String) -> [String] {
        var segments = text
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if segments.count == 1, segments[0].count > 80 {
            var chunks: [String] = []
            var current = ""
            for ch in segments[0] {
                current.append(ch)
                if current.count >= 55, "。！？!?…；;，".contains(ch) {
                    chunks.append(current)
                    current = ""
                }
            }
            if !current.isEmpty {
                if let last = chunks.indices.last, current.count < 15 {
                    chunks[last] += current
                } else {
                    chunks.append(current)
                }
            }
            if chunks.count > 1 { segments = chunks }
        }
        if segments.count > 4 {
            let head = segments.prefix(3)
            let tail = segments.dropFirst(3).joined(separator: " ")
            segments = Array(head) + [tail]
        }
        return segments
    }
}
