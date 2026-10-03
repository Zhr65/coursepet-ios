// MARK: - AI 回复语音朗读（功能 B：TTS，AVSpeechSynthesizer 封装）
// 两种用法，音频会话归属不同，互不打架：
//   1. 聊天页：单条消息点读 / 自动朗读 —— speak(id:text:) / toggle / speakIfNeeded / stop
//      自己管音频会话（.playback + duckOthers，读完释放）
//   2. 通话模式（AgentCallSession）：整段回答按句排队播报，播完/被打断回调
//      —— beginCallMode / speakCallSentences / interruptCall / endCallMode
//      完全不碰音频会话（由通话会话统一持有 .playAndRecord + .voiceChat，系统回声消除），
//      否则两边抢 AVAudioSession 会把通话弄哑。
import AVFoundation

@MainActor
final class AgentSpeech: NSObject, ObservableObject {
    static let shared = AgentSpeech()

    /// 正在朗读的消息 id（驱动气泡按钮状态：speaker.wave.2 ↔ stop.circle.fill）；通话中为 "call"
    @Published private(set) var speakingMessageID: String?

    /// 是否处于通话播报模式（聊天页据此跳过自动朗读，避免和通话抢嘴/抢音频会话）
    private(set) var isCallMode = false

    var isAutoSpeak: Bool {
        get { UserDefaults.standard.bool(forKey: "agent.autoSpeak") }
        set { UserDefaults.standard.set(newValue, forKey: "agent.autoSpeak") }
    }

    private let synthesizer = AVSpeechSynthesizer()
    /// 中文音色：优先系统"优质/增强"音色（比默认 Tingting 自然得多，用户可在系统里下载）
    private lazy var chineseVoice: AVSpeechSynthesisVoice? = Self.bestChineseVoice()

    // 通话模式的"当前批次"与回调
    /// 当前这批待播 utterance 的身份集合：回调只认集合里的，
    /// 这样"被主动停掉的旧批"无论回来几个 didCancel 都会被丢掉，不会误触发新批的回调
    private var callBatchIDs: Set<ObjectIdentifier> = []
    private var callOnFinish: (() -> Void)?
    private var callOnInterrupt: (() -> Void)?

    private override init() {
        super.init()
        synthesizer.delegate = self
    }

    // MARK: - 聊天模式

    /// 点气泡按钮：同一条再点=停止；不同条=停旧读新
    func toggle(_ id: String, text: String) {
        if speakingMessageID == id {
            stop()
        } else {
            speak(id: id, text: text)
        }
    }

    /// 自动朗读入口：正在录音 / 正在通话时跳过（音频会话冲突兜底）
    func speakIfNeeded(id: String, text: String, suppressed: Bool) {
        guard isAutoSpeak, !suppressed, !isCallMode else { return }
        speak(id: id, text: text)
    }

    /// 停止聊天模式的朗读。通话中调用是空操作——不许把正在进行的通话打断。
    func stop() {
        guard !isCallMode else { return }
        guard synthesizer.isSpeaking else {
            speakingMessageID = nil
            return
        }
        // didCancel 回调会负责清 speakingMessageID 与释放会话
        synthesizer.stopSpeaking(at: .immediate)
    }

    private func speak(id: String, text: String) {
        // 先停上一条（旧回调异步清理，这里直接覆盖状态即可）
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = chineseVoice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate  // 系统默认语速，中文最自然
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, options: .duckOthers)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            // 会话切不过去（如录音中）：放弃本次朗读，不打断主链路
            speakingMessageID = nil
            return
        }
        speakingMessageID = id
        synthesizer.speak(utterance)
    }

    // MARK: - 通话模式（AgentCallSession 专用）

    /// 进通话播报模式（音频会话由通话会话持有，这里只切模式标志）
    func beginCallMode() {
        isCallMode = true
    }

    /// 整段回答按句排队播报：全部念完 → onFinish；被 interruptCall 打断 → onInterrupt。
    /// 不在这里动音频会话——通话期间由 AgentCallSession 统一持有。
    func speakCallSentences(_ sentences: [String],
                            onFinish: @escaping () -> Void,
                            onInterrupt: @escaping () -> Void) {
        guard isCallMode else { return }
        // 丢掉旧批（旧批的 didCancel 异步回来时会被身份校验拦掉）
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        callBatchIDs.removeAll()
        callOnFinish = onFinish
        callOnInterrupt = onInterrupt

        guard !sentences.isEmpty else {
            let cb = callOnFinish
            callOnFinish = nil
            callOnInterrupt = nil
            cb?()
            return
        }
        speakingMessageID = "call"
        for (i, sentence) in sentences.enumerated() {
            let u = AVSpeechUtterance(string: sentence)
            u.voice = chineseVoice
            u.rate = AVSpeechUtteranceDefaultSpeechRate
            // 句间小停顿，像真人换气（末句不留）
            u.postUtteranceDelay = i == sentences.count - 1 ? 0 : 0.06
            callBatchIDs.insert(ObjectIdentifier(u))
            synthesizer.speak(u)
        }
    }

    /// 通话打断（barge-in）：立刻闭嘴并回调。
    /// 关键：即使此刻已经念完（没有 didCancel 回调），也保证回调一次——会话状态机必须被推进。
    func interruptCall() {
        guard isCallMode else { return }
        let cb = callOnInterrupt
        callOnInterrupt = nil
        callOnFinish = nil
        callBatchIDs.removeAll()
        speakingMessageID = nil
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        cb?()
    }

    /// 挂断：退出通话播报模式（之后聊天模式的朗读恢复正常）
    func endCallMode() {
        isCallMode = false
        callBatchIDs.removeAll()
        callOnFinish = nil
        callOnInterrupt = nil
        speakingMessageID = nil
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
    }

    // MARK: - 文本预处理（通话播报用）

    /// 口语清洗：去掉 Markdown 标记与 emoji，换行变句读（念出来才像人话）
    static func spokenClean(_ text: String) -> String {
        var s = text
        s = s.replacingOccurrences(of: "**", with: "")
        s = s.replacingOccurrences(of: "##", with: "")
        s = s.replacingOccurrences(of: "#", with: "")
        s = s.replacingOccurrences(of: "`", with: "")
        // 行首项目符 / 编号："- xxx"、"1. xxx"、"• xxx"
        s = s.replacingOccurrences(of: #"(?m)^\s*[-*•]\s+"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?m)^\s*\d+[.、)]\s*"#, with: "", options: .regularExpression)
        // emoji / 变体选择符 / 零宽连接符：TTS 会念成"笑脸"，必须去掉
        s = s.unicodeScalars.filter { !isEmojiScalar($0) }.map { String($0) }.joined()
        // 换行变句读
        s = s.replacingOccurrences(of: "\n", with: "。")
        s = s.replacingOccurrences(of: "。。", with: "。")
        s = s.replacingOccurrences(of: "。.", with: "。")
        return s
    }

    private static func isEmojiScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x1F000...0x1FAFF,   // 表情/符号/补充符号/扩展-A
             0x2600...0x27BF,     // 杂项符号 / 装饰符号
             0x2B00...0x2BFF,     // 杂项符号与箭头
             0xFE00...0xFE0F,     // 变体选择符
             0x200D,              // 零宽连接符（组合 emoji）
             0x20E3:              // 组合包围键帽
            return true
        default:
            return false
        }
    }

    /// 切成适合"一口气念一句"的短句：按句末标点切，过短的碎句合并（"嗯。好的。"→"嗯，好的。"）
    static func splitSentences(_ text: String) -> [String] {
        var raw: [String] = []
        var current = ""
        for ch in text {
            current.append(ch)
            if "。！？!?…；;\n".contains(ch) {
                let t = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { raw.append(t) }
                current = ""
            }
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { raw.append(tail) }

        var merged: [String] = []
        for s in raw {
            if let last = merged.last, last.count < 8 || s.count < 6 {
                merged[merged.count - 1] = last + s
            } else {
                merged.append(s)
            }
        }
        return merged.isEmpty ? [text] : merged
    }

    /// 选一个中文音色：优先系统优质（premium）→ 增强（enhanced）→ 默认
    private static func bestChineseVoice() -> AVSpeechSynthesisVoice? {
        let zhVoices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("zh-CN") }
        if let premium = zhVoices.first(where: { $0.quality == .premium }) { return premium }
        if let enhanced = zhVoices.first(where: { $0.quality == .enhanced }) { return enhanced }
        return AVSpeechSynthesisVoice(language: "zh-CN")
    }
}

// MARK: - AVSpeechSynthesizerDelegate（回调都在后台线程，切回主 actor 处理）
extension AgentSpeech: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.handleFinish(utterance) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.handleCancel(utterance) }
    }

    private func handleFinish(_ utterance: AVSpeechUtterance) {
        guard isCallMode else {
            finishChatSpeaking()
            return
        }
        // 只认当前批次的 utterance（旧批残留回调直接丢）
        guard callBatchIDs.remove(ObjectIdentifier(utterance)) != nil else { return }
        guard callBatchIDs.isEmpty else { return }
        let cb = callOnFinish
        callOnFinish = nil
        callOnInterrupt = nil
        cb?()
    }

    private func handleCancel(_ utterance: AVSpeechUtterance) {
        guard isCallMode else {
            finishChatSpeaking()
            return
        }
        // 只认当前批次的 utterance：主动停掉的旧批 / 已手动回调过的批次，一律忽略
        guard callBatchIDs.remove(ObjectIdentifier(utterance)) != nil else { return }
        // 被打断：整批作废，转交打断回调（不释放音频会话——会话归 AgentCallSession 管）
        callBatchIDs.removeAll()
        speakingMessageID = nil
        let cb = callOnInterrupt
        callOnInterrupt = nil
        callOnFinish = nil
        cb?()
    }

    /// 聊天模式收尾：清状态 + 释放音频会话（notifyOthers 让被压低的其他 App 音乐恢复）
    private func finishChatSpeaking() {
        speakingMessageID = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}