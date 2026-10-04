// MARK: - 语音通话会话（对标 ChatGPT Advanced Voice 的"打电话"模式）
// 一句话概括：开麦持续听 → 静音自动断句 → 交给 AgentEngine 回答 → 念出来 → 回到听。
//
// 四个关键设计（都是被真机问题逼出来的）：
//   1. 统一音频会话：通话要"同时开麦 + 放音"，必须用 .playAndRecord + .videoChat。
//      videoChat 模式带系统回声消除（AEC），否则宠物会把自己的话录进来自问自答；
//      不用 voiceChat 是因为它是窄带电话音质，会把宠物的音色弄闷。
//      现有记账的 .record / 朗读的 .playback 两套在通话期间一律不碰（AgentSpeech 已按模式隔离）。
//   2. 不用"按一下说一句"：装一次 tap 全程不拆（拆/装会爆音+丢首字），识别任务静音收尾后自动重挂。
//   3. 断句靠双判：音量阈值（有人在说）+ 静音计时（说完了）——单靠识别结果在嘈杂环境会乱断。
//   4. 打断（barge-in）：说话时不停监测音量，超过"自适应打断线"持续 0.3s 就闭嘴转听——
//      念完了也保证状态机推进（interruptCall 自带兜底回调）。
//
// 线程约定：本类是 @MainActor；音频 tap 在后台线程跑，只能通过 AudioFeed（带锁）与主线程交换数据。
import Foundation
import Speech
import AVFoundation

// MARK: 音频 tap（后台线程）→ 主线程 的线程安全通道
/// 直接跨线程摸 @MainActor 属性会数据竞争，用一个带锁的小盒子做双向通道：
/// 音频线程写"最新音量"，主线程写"要不要喂识别器"。
private final class AudioFeed: @unchecked Sendable {
    private let lock = NSLock()
    private var _levelDB: Float = -160
    private var _feeding = false
    private var _request: SFSpeechAudioBufferRecognitionRequest?

    var levelDB: Float { lock.lock(); defer { lock.unlock() }; return _levelDB }
    var isFeeding: Bool { lock.lock(); defer { lock.unlock() }; return _feeding }
    var request: SFSpeechAudioBufferRecognitionRequest? { lock.lock(); defer { lock.unlock() }; return _request }

    func update(levelDB: Float) { lock.lock(); _levelDB = levelDB; lock.unlock() }

    func set(request: SFSpeechAudioBufferRecognitionRequest?, feeding: Bool) {
        lock.lock(); _request = request; _feeding = feeding; lock.unlock()
    }

    func setFeeding(_ on: Bool) { lock.lock(); _feeding = on; lock.unlock() }
}

// MARK: 一帧音频的响度（dBFS，-160 ≈ 静音）
/// 文件级函数：不受 @MainActor 隔离约束，音频线程可直接调用。
private func audioLevelDB(_ buffer: AVAudioPCMBuffer) -> Float {
    guard let channel = buffer.floatChannelData?[0] else { return -160 }
    let n = Int(buffer.frameLength)
    guard n > 0 else { return -160 }
    var sum: Float = 0
    for i in 0..<n {
        let v = channel[i]
        sum += v * v
    }
    let rms = sqrt(sum / Float(n))
    return rms > 0 ? 20 * log10(rms) : -160
}

// MARK: - 通话会话
@MainActor
final class AgentCallSession: ObservableObject {

    enum Phase: Equatable {
        case idle        // 未开始 / 已挂断
        case listening   // 在听主人说
        case thinking    // 已提交，等宠物想
        case speaking    // 宠物正在说
    }

    // MARK: 对外状态（驱动通话页 UI）
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var liveTranscript = ""    // 主人正在说的话（实时转写）
    @Published private(set) var answerText = ""        // 宠物正在说的内容（字幕）
    @Published private(set) var elapsedSeconds = 0
    @Published private(set) var turns = 0
    @Published private(set) var softReminder: String?  // 连续通话 30 分钟的软提示（不强制挂断）
    @Published var errorMessage: String?

    // MARK: 依赖
    private weak var engine: AgentEngine?

    // MARK: 音频
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    private let audioEngine = AVAudioEngine()
    private let feed = AudioFeed()
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognitionGeneration = 0   // 识别任务代际号（见 restartRecognition）
    private var recognitionErrorStreak = 0  // 连续错误次数（退避重挂 + 熔断）
    private var tapInstalled = false

    // MARK: 断句调参（按真机手感可微调）
    private let speechThresholdDB: Float = -38   // 判定"有人在说话"的音量线
    private let bargeThresholdDB: Float = -20    // 打断的音量线（更高，防 AEC 残留误触）
    private let silenceTimeout: TimeInterval = 1.15   // 静音多久算说完一句
    private let minSpeechDuration: TimeInterval = 0.35 // 太短的（咳嗽/碰麦）不提交
    private let softLimitSeconds = 30 * 60

    // MARK: 运行时
    private var speechStartedAt: Date?
    private var lastVoiceAt: Date?
    private var bargeFrames = 0
    private var speakNoiseEMA: Float?   // 放音期间学到的"底噪"（见 tick 的自适应打断线）
    private var startedAt: Date?
    private var reminderShown = false
    private var tickTimer: Timer?
    /// 是否已"接通"（用它而不是 phase 把关：权限被拒时 phase 还是 idle，但引擎已切通话模式，必须能退回去）
    private var didStart = false

    // MARK: - 生命周期

    /// 开始通话：引擎进通话模式（短回答 + 通话守则 + 工具过程静默），然后申请权限起音频
    func start(engine: AgentEngine) {
        guard !didStart else { return }
        didStart = true
        self.engine = engine
        errorMessage = nil
        liveTranscript = ""
        answerText = ""
        elapsedSeconds = 0
        turns = 0
        softReminder = nil
        reminderShown = false
        startedAt = Date()

        engine.isVoiceMode = true
        requestPermissions()
    }

    /// 挂断：停音频、退通话模式、把音频会话还回去（引擎回到打字模式）
    func end() {
        guard didStart else { return }
        didStart = false
        phase = .idle
        tickTimer?.invalidate()
        tickTimer = nil

        AgentSpeech.shared.endCallMode()
        recognitionTask?.cancel()
        recognitionTask = nil
        feed.set(request: nil, feeding: false)

        if tapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        engine?.isVoiceMode = false
        engine = nil
    }

    // MARK: - 权限（语音识别 → 麦克风，逐级申请）
    private func requestPermissions() {
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            Task { @MainActor in
                guard let self else { return }
                guard status == .authorized else {
                    self.errorMessage = "需要语音识别权限：设置 → 隐私与安全 → 语音识别"
                    return
                }
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    Task { @MainActor in
                        // 注意：这里的 self 已经被外层 guard let 解包成非 Optional，不能再 guard let self
                        guard self.didStart else { return }   // 等权限弹窗时可能已经挂断了
                        guard granted else {
                            self.errorMessage = "需要麦克风权限：设置 → 隐私与安全 → 麦克风"
                            return
                        }
                        self.beginAudio()
                    }
                }
            }
        }
    }

    // MARK: - 起音频（统一会话 + 一次 tap + 心跳定时器）
    private func beginAudio() {
        guard recognizer != nil else {
            errorMessage = "这台设备不支持中文语音识别。"
            return
        }
        do {
            try configureAudioSession()
            let input = audioEngine.inputNode
            // 显式打开输入节点的语音处理（AEC 回声消除）：只靠 .voiceChat 模式在部分机型/路由上不够，
            // 必须赶在读取格式与装 tap 之前打开（它会改变输入格式）
            try? input.setVoiceProcessingEnabled(true)
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0 else {
                errorMessage = "麦克风还没准备好，看看是不是别的 App 正在录音？"
                return
            }
            // ⚠️ 这里在音频线程：只能碰 AudioFeed（带锁），不能摸 @MainActor 状态
            let feedBox = feed
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                feedBox.update(levelDB: audioLevelDB(buffer))
                if feedBox.isFeeding { feedBox.request?.append(buffer) }
            }
            tapInstalled = true
            // 通话朗读引擎接入：CosyVoice 播放节点必须赶在 engine start 之前挂上
            // （没配百炼 Key / 选了系统音色 → beginCallMode 内部自动走系统 TTS）
            AgentSpeech.shared.beginCallMode(engine: audioEngine)
            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            errorMessage = "通话启动失败：\(error.localizedDescription)"
            return
        }

        // 0.1s 心跳：断句 + 打断 + 计时（比每帧 dispatch 到主线程省得多）
        tickTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }

        // 先打个招呼：一是自然，二是让主人立刻确认"能听见"
        greet()
    }

    /// 通话专用音频会话：同时收音+放音，videoChat 模式自带回声消除（AEC）
    /// 用 videoChat 而不是 voiceChat：两者都开 AEC，但 voiceChat 是窄带电话音质，
    /// 宠物的 TTS 会被"电话化"，音色更闷——用户最在意的就是音色。
    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord,
                                mode: .videoChat,
                                options: [.defaultToSpeaker])
        try session.setActive(true)
    }

    private func greet() {
        let greeting = "喂，我在呢，说吧～"
        answerText = greeting
        speakNoiseEMA = nil
        bargeFrames = 0
        phase = .speaking
        AgentSpeech.shared.speakCallSentences(
            AgentSpeech.splitSentences(greeting),
            onFinish: { [weak self] in self?.enterListening() },
            onInterrupt: { [weak self] in self?.enterListening() }
        )
    }

    // MARK: - 状态迁移

    /// 进入"听"：清掉上一轮的转写/计时，挂上新的识别任务开始喂音频
    /// （answerText 故意不清：上一句回答留在屏幕上给对方一个回看，等他说新话时自然被盖掉）
    private func enterListening() {
        guard phase != .idle else { return }
        phase = .listening
        liveTranscript = ""
        speechStartedAt = nil
        lastVoiceAt = nil
        bargeFrames = 0
        restartRecognition()
    }

    /// 挂上（或重挂）识别任务：端侧识别、实时部分结果、带标点
    private func restartRecognition() {
        recognitionTask?.cancel()
        recognitionTask = nil

        guard let recognizer else { return }
        // 代际号：cancel 掉的旧任务可能还会回调一次（error/isFinal），
        // 用它把"上一代"的回调全部丢掉，否则会连锁重挂出无限循环
        recognitionGeneration += 1
        let generation = recognitionGeneration

        let request = SFSpeechAudioBufferRecognitionRequest()
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true   // 通话内容不出设备
        }
        request.shouldReportPartialResults = true
        request.addsPunctuation = true

        // 只有"在听"的时候才喂音频：说话/思考期间不喂，避免把宠物的 TTS 录进去形成自问自答
        feed.set(request: request, feeding: phase == .listening)

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self, self.phase == .listening,
                      generation == self.recognitionGeneration else { return }
                if let result {
                    self.liveTranscript = result.bestTranscription.formattedString
                    self.recognitionErrorStreak = 0
                }
                if error != nil {
                    // 识别任务出错（常见于长时间静音/网络抖动）：退避重挂，避免瞬时错误打成死循环
                    self.recognitionErrorStreak += 1
                    if self.recognitionErrorStreak >= 4 {
                        self.errorMessage = "语音识别中断了，挂断重开一次试试。"
                        return
                    }
                    let backoff = UInt64(self.recognitionErrorStreak) * 400_000_000
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: backoff)
                        guard self.phase == .listening,
                              generation == self.recognitionGeneration else { return }
                        self.restartRecognition()
                    }
                } else if result?.isFinal == true {
                    // 长时间静音会让识别任务收尾：只要还在通话就重新挂上，保持"一直在听"
                    if self.phase == .listening { self.restartRecognition() }
                }
            }
        }
    }

    // MARK: - 心跳：断句 / 打断 / 计时
    private func tick() {
        if let startedAt {
            elapsedSeconds = Int(Date().timeIntervalSince(startedAt))
            if !reminderShown, elapsedSeconds >= softLimitSeconds {
                reminderShown = true
                softReminder = "咱们聊了半小时啦，挂掉歇会儿？"
            }
        }

        let now = Date()
        let level = feed.levelDB

        switch phase {
        case .listening:
            if level > speechThresholdDB {
                if speechStartedAt == nil { speechStartedAt = now }
                lastVoiceAt = now
            }
            // 说完一句的三个条件：有转写内容 + 静了够久 + 确实说过一小会儿（防咳嗽/碰麦误提交）
            if let speechStart = speechStartedAt,
               let lastVoice = lastVoiceAt,
               !liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               now.timeIntervalSince(lastVoice) > silenceTimeout,
               lastVoice.timeIntervalSince(speechStart) >= minSpeechDuration {
                submitTurn(liveTranscript)
            }

        case .speaking:
            // 打断（barge-in）：自适应打断线。
            // speakNoiseEMA 学到"当前放音漏进麦克风的底噪"，主人音量得比底噪高出 7dB 才算插话——
            // AEC 生效时底噪很低（很灵敏），AEC 不理想时也不会被宠物自己的声音触发（自问自答）。
            speakNoiseEMA = (speakNoiseEMA.map { $0 * 0.8 + level * 0.2 }) ?? level
            let bargeLine = max(bargeThresholdDB, (speakNoiseEMA ?? -160) + 7)
            if level > bargeLine {
                bargeFrames += 1
                if bargeFrames >= 3 {
                    bargeFrames = 0
                    AgentSpeech.shared.interruptCall()   // 念完了也会回调 → 状态机一定被推进
                }
            } else {
                bargeFrames = 0
            }

        case .thinking, .idle:
            break
        }
    }

    // MARK: - 一轮对话

    private func submitTurn(_ raw: String) {
        guard let engine else { return }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            enterListening()
            return
        }

        phase = .thinking
        feed.setFeeding(false)      // 思考期间不收音频（主人这会儿补话会丢，但换来不会被杂音干扰）
        speechStartedAt = nil
        lastVoiceAt = nil
        liveTranscript = ""
        turns += 1

        Task { [weak self] in
            guard let self else { return }
            // 复用无 UI 入口：跑完整 ReAct 循环后把最终回答文本交回来
            let answer = await engine.askOnce(text)
            guard self.phase == .thinking else { return }   // 期间可能已被挂断/打断
            self.speak(answer)
        }
    }

    private func speak(_ answer: String) {
        // 念之前先洗一遍：去 Markdown / 去 emoji（念出来是"笑脸"，很怪）
        let clean = AgentSpeech.spokenClean(answer).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else {
            enterListening()
            return
        }
        answerText = clean
        speakNoiseEMA = nil
        bargeFrames = 0
        phase = .speaking
        AgentSpeech.shared.speakCallSentences(
            AgentSpeech.splitSentences(clean),
            onFinish: { [weak self] in self?.enterListening() },
            onInterrupt: { [weak self] in self?.enterListening() }
        )
    }

    // MARK: - 给 UI 用的格式化
    var elapsedText: String {
        String(format: "%02d:%02d", elapsedSeconds / 60, elapsedSeconds % 60)
    }
}