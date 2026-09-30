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
                LinearGradient(colors: PagePalette.feed, startPoint: .topLeading, endPoint: .bottomTrailing)
                    .ignoresSafeArea()
            )
            .navigationTitle("和\(dataManager.petName)聊聊")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showLibrary = true
                    } label: {
                        Label("课件知识库", systemImage: "books.vertical")
                    }
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
                    Button {
                        engine.reset()
                    } label: {
                        Label("新对话", systemImage: "arrow.counterclockwise")
                    }
                }
            }
            .sheet(isPresented: $showLibrary) {
                CourseLibraryView(presentedAsSheet: true)
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
                    // 开场白
                    headerBubble
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

    private var headerBubble: some View {
        Text("我是\(dataManager.petName)！课表、作业、账单、步数、天气都可以问我，或者直接说“帮我记一下 XX”")
            .font(.footnote)
            .foregroundColor(.secondary)
            .multilineTextAlignment(.center)
            .padding(.vertical, 6)
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
                    .background(Color(.systemIndigo))
                    .foregroundColor(.white)
                    .clipShape(ChatBubbleShape(isMine: true))
            }
        case .assistant:
            HStack(alignment: .bottom, spacing: 8) {
                // 聊天头像跟随形象商店当前形象（帧图加载失败显示爪印，与灵动岛同款组件）
                LiveActivitySafePet(action: "happy", charId: dataManager.charId, size: 30)
                Text(msg.text)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial)
                    .clipShape(ChatBubbleShape(isMine: false))
                // 朗读按钮：正在读这条时变成停止
                Button {
                    tts.toggle(msg.id.uuidString, text: msg.text)
                } label: {
                    Image(systemName: tts.speakingMessageID == msg.id.uuidString ? "stop.circle.fill" : "speaker.wave.2")
                        .font(.caption2)
                        .foregroundColor(tts.speakingMessageID == msg.id.uuidString ? .indigo : .secondary)
                }
                Spacer(minLength: 24)
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
            // 思考中的头像同样跟随当前形象
            LiveActivitySafePet(action: "idle", charId: dataManager.charId, size: 30)
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
                .background(.ultraThinMaterial)
                .clipShape(ChatBubbleShape(isMine: false))
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

// MARK: - 聊天气泡形状（多留一个小尾巴）
struct ChatBubbleShape: Shape {
    let isMine: Bool

    func path(in rect: CGRect) -> Path {
        let radius: CGFloat = 16
        let path = UIBezierPath(roundedRect: rect,
                                byRoundingCorners: isMine ? [.topLeft, .bottomLeft, .bottomRight] : [.topRight, .bottomLeft, .bottomRight],
                                cornerRadii: CGSize(width: radius, height: radius))
        return Path(path.cgPath)
    }
}

// （引擎的 reset() 已移入 AgentEngine 类体内——extension 无法访问 private 成员）
