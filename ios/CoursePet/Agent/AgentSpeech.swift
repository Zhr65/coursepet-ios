// MARK: - AI 回复语音朗读（功能 B：TTS，AVSpeechSynthesizer 封装）
// 无需任何权限（Info.plist 零改动）；与语音识别共用音频会话的冲突处理：
//   1. 朗读开始前把会话切成 .playback（duckOthers：压低其他 App 的声音）
//   2. 朗读结束/取消在异步 delegate 回调里释放会话（不在 stopSpeaking 后同步抢 setActive）
//   3. 用户点麦克风录音前必须先 stop()（.record 类别会顶掉播放）
//   4. 录音中收到新回复不自动朗读（speakIfNeeded 的 suppressed 参数）
import AVFoundation

@MainActor
final class AgentSpeech: NSObject, ObservableObject {
    static let shared = AgentSpeech()

    /// 正在朗读的消息 id（驱动气泡按钮状态：speaker.wave.2 ↔ stop.circle.fill）
    @Published private(set) var speakingMessageID: String?

    var isAutoSpeak: Bool {
        get { UserDefaults.standard.bool(forKey: "agent.autoSpeak") }
        set { UserDefaults.standard.set(newValue, forKey: "agent.autoSpeak") }
    }

    private let synthesizer = AVSpeechSynthesizer()

    private override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// 点气泡按钮：同一条再点=停止；不同条=停旧读新
    func toggle(_ id: String, text: String) {
        if speakingMessageID == id {
            stop()
        } else {
            speak(id: id, text: text)
        }
    }

    /// 自动朗读入口：正在录音时跳过（音频会话冲突兜底）
    func speakIfNeeded(id: String, text: String, suppressed: Bool) {
        guard isAutoSpeak, !suppressed else { return }
        speak(id: id, text: text)
    }

    func stop() {
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
        utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
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
}

extension AgentSpeech: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finishSpeaking() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finishSpeaking() }
    }

    private func finishSpeaking() {
        speakingMessageID = nil
        // 释放音频会话（notifyOthersOnDeactivation 让被压低的其他 App 音乐恢复）
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
