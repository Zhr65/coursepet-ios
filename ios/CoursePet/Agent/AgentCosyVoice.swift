// MARK: - CosyVoice 流式语音合成（阿里百炼 DashScope WebSocket 协议）
// 定位：通话模式的"高级嗓音"。与图像生成共用同一条百炼 Key（dashscopeKey），
//       端侧直连 wss://dashscope.aliyuncs.com，服务器不参与。
//       没配 Key / 用户选了系统音色 / 连接失败 → AgentSpeech 无缝回落 AVSpeechSynthesizer。
//
// 工作方式（对标 DashScope CosyVoice 官方 WS 协议）：
//   1. run-task（streaming=out）→ 收 task-started
//   2. continue-task 提交整段文本 → finish-task
//   3. 服务端以二进制帧推 PCM 音频（16bit 小端单声道 24kHz），边收边转 Float32 排进
//      AVAudioPlayerNode 播放——首包通常 <1s 就出声，比"整段合成完再播"快得多
//   4. task-finished 且全部 buffer 播完 → onAllPlayed；任何异常 → onError（带出声标记）
//
// 播放挂在通话的 AVAudioEngine 上（AgentCallSession 持有 .videoChat AEC 会话），
// 因此回声消除照常生效、不会自问自答；音量走 playerNode.volume（滑块实时生效）。
// 注意：节点必须在 engine.start() 之前 attach/connect（beginCall 由通话会话保证时序）。
import Foundation
import AVFoundation

// MARK: 音色常量（故意不放 @MainActor 类里：设置页 @State 初始化器是非隔离上下文，直接读才不踩 actor 隔离）
/// cosyvoice-v1 官方音色（挑了常用的几个）
enum AgentCosyVoiceConfig {
    static let defaultVoice = "longxiaochun"
    static let voices: [(id: String, label: String)] = [
        ("longxiaochun", "小淳 · 元气女生"),
        ("longxiaoxia", "小夏 · 软萌少女"),
        ("loongbella", "贝拉 · 知性御姐"),
        ("longwan", "小婉 · 温柔女声"),
        ("longcheng", "小橙 · 阳光暖男"),
        ("longhua", "小华 · 沉稳男声"),
        ("longfei", "小飞 · 清爽男声"),
        ("longmiao", "小喵 · 二次元萌妹"),
    ]
}

@MainActor
final class AgentCosyVoice {
    static let shared = AgentCosyVoice()

    // MARK: 配置

    /// 复用百炼 Key（与图像生成同一条目）：没配 Key 就一直走系统 TTS，零打扰
    static var isConfigured: Bool { !AgentImageGen.loadKey().isEmpty }

    /// 音色选择（"" = 用系统音色）。存 UserDefaults，设置页 Picker 直接读写。
    static var voice: String {
        get { UserDefaults.standard.string(forKey: "agent.cosyvoice.voice") ?? AgentCosyVoiceConfig.defaultVoice }
        set { UserDefaults.standard.set(newValue, forKey: "agent.cosyvoice.voice") }
    }

    private static let model = "cosyvoice-v1"
    private static let sampleRate: Double = 24000

    // MARK: 音频（节点随通话挂/摘，跨批复用）

    private static let audioFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                   sampleRate: sampleRate,
                                                   channels: 1, interleaved: false)!
    private let playerNode = AVAudioPlayerNode()
    private weak var engine: AVAudioEngine?

    // MARK: 批次状态（一次 speak = 一批；旧批回调一律丢弃）

    private var batchID = 0
    private var dashTaskID = ""          // run-task 时生成的协议 task_id
    private var fullText = ""            // task-started 后要提交的文本
    private var wsTask: URLSessionWebSocketTask?
    private var pendingBytes = Data()    // 不足 2 字节对齐的音频尾巴
    private var scheduled = 0            // 已排进播放器的 buffer 数
    private var played = 0               // 已播完的 buffer 数
    private var serverDone = false       // 收到 task-finished
    private var completed = false        // 本批已收尾（finish/interrupt/error 三选一，只走一次）
    private(set) var hasStartedPlaying = false   // 本批是否出过声（错误时 AgentSpeech 决定回落策略用）
    private var watchdog: Timer?
    private var onAllPlayed: (() -> Void)?
    private var onError: (() -> Void)?

    private init() {}

    // MARK: 通话接入 / 退出

    /// 通话开始时挂到通话引擎。必须在 engine.start() 之前调用；
    /// 未配 Key / 选了系统音色 → 返回 false（AgentSpeech 走系统 TTS）。
    func beginCall(engine: AVAudioEngine) -> Bool {
        guard Self.isConfigured, !Self.voice.isEmpty else { return false }
        // 保险：上一通异常退出没摘干净时，先从旧引擎摘下来（对同一节点重复 attach 会崩）
        if let old = self.engine, old !== engine {
            old.disconnectNodeOutput(playerNode)
            old.detach(playerNode)
        }
        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: Self.audioFormat)
        self.engine = engine
        playerNode.volume = Float(UserDefaults.standard.object(forKey: "agent.callVolume") as? Float ?? 0.9)
        return true
    }

    /// 挂断：断流、停播、摘节点
    func endCall() {
        cancelBatch()
        if let engine, playerNode.engine != nil {
            engine.disconnectNodeOutput(playerNode)
            engine.detach(playerNode)
        }
        self.engine = nil
    }

    /// 实时音量（通话页音量条，不用等下一句）
    func setVolume(_ v: Float) { playerNode.volume = max(0, min(1, v)) }

    // MARK: 说一句话（整段文本一次提交，音频流式回来边收边播）

    func speak(_ text: String, onAllPlayed: @escaping () -> Void, onError: @escaping () -> Void) {
        cancelBatch()   // 掐掉上一批（正常流程不会有活跃批，双保险）
        let key = AgentImageGen.loadKey()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !trimmed.isEmpty else {
            onError()
            return
        }

        batchID += 1
        let id = batchID
        dashTaskID = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        fullText = trimmed
        self.onAllPlayed = onAllPlayed
        self.onError = onError
        pendingBytes = Data()
        scheduled = 0
        played = 0
        serverDone = false
        completed = false
        hasStartedPlaying = false

        // 看门狗：首包 10s 不来（断网/服务异常）就报错回落，不能让通话卡死在"说"
        watchdog = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.batchID == id, !self.completed, !self.hasStartedPlaying else { return }
                self.fail(batch: id)
            }
        }

        var req = URLRequest(url: URL(string: "wss://dashscope.aliyuncs.com/api-ws/v1/inference")!)
        req.timeoutInterval = 10
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("CoursePet/1.0", forHTTPHeaderField: "user-agent")
        let ws = URLSession.shared.webSocketTask(with: req)
        wsTask = ws
        ws.resume()

        let runTask: [String: Any] = [
            "header": ["action": "run-task", "task_id": dashTaskID, "streaming": "out"],
            "payload": [
                "task_group": "audio",
                "task": "tts",
                "function": "SpeechSynthesizer",
                "model": Self.model,
                "parameters": [
                    "text_type": "PlainText",
                    "voice": Self.voice,
                    "format": "pcm",
                    "sample_rate": Int(Self.sampleRate),
                    "volume": 50,
                    "rate": 1.0,
                    "pitch": 1.0
                ],
                "input": [String: Any]()
            ]
        ]
        Task { [weak self] in
            guard let self, self.batchID == id else { return }
            do {
                try await ws.send(.string(Self.json(runTask)))
                self.receiveLoop(batch: id)
            } catch {
                self.fail(batch: id)
            }
        }
    }

    /// 主动掐断（打断/新批覆盖/挂断）：立刻停播、断流，并作废本批所有回调
    func cancelBatch() {
        batchID += 1
        watchdog?.invalidate()
        watchdog = nil
        wsTask?.cancel(with: .goingAway)
        wsTask = nil
        playerNode.stop()   // 丢弃未播的 buffer；下一批首包到时重新 play()
        pendingBytes = Data()
        scheduled = 0
        played = 0
        serverDone = false
        completed = true
        hasStartedPlaying = false
        onAllPlayed = nil
        onError = nil
    }

    // MARK: WS 收包循环

    private func receiveLoop(batch id: Int) {
        guard let ws = wsTask, batchID == id, !completed else { return }
        ws.receive { [weak self] result in
            Task { @MainActor in
                guard let self, self.batchID == id, !self.completed else { return }
                switch result {
                case .success(let msg):
                    switch msg {
                    case .data(let d):
                        self.ingest(d, batch: id)
                        self.receiveLoop(batch: id)
                    case .string(let s):
                        if self.handleServerEvent(s, batch: id) {
                            self.receiveLoop(batch: id)
                        }
                    @unknown default:
                        self.receiveLoop(batch: id)
                    }
                case .failure:
                    // 正常收尾（task-finished）后服务端也会关连接，但那时 completed 已置位，
                    // 这里只剩"没收尾就断了"的情况 → 按失败处理
                    self.fail(batch: id)
                }
            }
        }
    }

    /// 文本帧事件。返回 false = 批已收尾，停止续收。
    private func handleServerEvent(_ s: String, batch id: Int) -> Bool {
        guard let d = s.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let header = obj["header"] as? [String: Any],
              let event = header["event"] as? String else { return true }
        switch event {
        case "task-started":
            submitText(batch: id)
            return true
        case "task-finished":
            serverDone = true
            if played >= scheduled {
                finish(batch: id)
                return false
            }
            return true   // 还有 buffer 在播，等最后一个播完触发 finish
        case "task-failed":
            let code = header["error_code"] as? String ?? ""
            let msg = header["error_message"] as? String ?? "未知错误"
            NSLog("CosyVoice task-failed: \(code) \(msg)")
            fail(batch: id)
            return false
        default:
            return true   // result-generated（计费信息）等，忽略
        }
    }

    private func submitText(batch id: Int) {
        let tid = dashTaskID
        sendJSON(["header": ["action": "continue-task", "task_id": tid],
                  "payload": ["input": ["text": fullText]]], batch: id)
        sendJSON(["header": ["action": "finish-task", "task_id": tid],
                  "payload": ["input": [String: Any]()]], batch: id)
    }

    private func sendJSON(_ obj: [String: Any], batch id: Int) {
        guard let ws = wsTask, batchID == id, !completed else { return }
        Task { [weak self] in
            guard let self, self.batchID == id, !self.completed else { return }
            do { try await ws.send(.string(Self.json(obj))) }
            catch { self.fail(batch: id) }
        }
    }

    private static func json(_ obj: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    // MARK: 音频 ingest（16bit 小端 → Float32 → 排队播放）

    private func ingest(_ chunk: Data, batch id: Int) {
        guard batchID == id, !completed, !chunk.isEmpty else { return }
        pendingBytes.append(chunk)
        let usable = pendingBytes.count - pendingBytes.count % 2
        guard usable > 0 else { return }
        let samples = usable / 2
        guard let buf = AVAudioPCMBuffer(pcmFormat: Self.audioFormat,
                                         frameCapacity: AVAudioFrameCount(samples)) else { return }
        buf.frameLength = AVAudioFrameCount(samples)
        let dst = buf.floatChannelData![0]
        pendingBytes.withUnsafeBytes { raw in
            let base = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
            for i in 0..<samples {
                let lo = UInt16(base[i * 2])
                let hi = UInt16(base[i * 2 + 1])
                dst[i] = Float(Int16(bitPattern: lo | (hi << 8))) / 32768.0
            }
        }
        pendingBytes.removeSubrange(0..<usable)

        if !hasStartedPlaying {
            hasStartedPlaying = true
            watchdog?.invalidate()
            watchdog = nil
            playerNode.play()
        }
        scheduled += 1
        playerNode.scheduleBuffer(buf, at: nil, options: [], completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in self?.bufferPlayed(batch: id) }
        }
    }

    private func bufferPlayed(batch id: Int) {
        guard batchID == id, !completed else { return }
        played += 1
        if serverDone && played >= scheduled {
            finish(batch: id)
        }
    }

    // MARK: 收尾（三选一：finish / fail / cancel）

    /// 正常播完：状态机推进（onAllPlayed → AgentSpeech 交回 onFinish）
    private func finish(batch id: Int) {
        guard batchID == id, !completed else { return }
        completed = true
        watchdog?.invalidate()
        watchdog = nil
        wsTask?.cancel(with: .goingAway)
        wsTask = nil
        playerNode.stop()
        let cb = onAllPlayed
        onAllPlayed = nil
        onError = nil
        cb?()
    }

    /// 异常收尾：hasStartedPlaying 保留本批的值，供 AgentSpeech 决定"当打断"还是"回落系统 TTS"
    private func fail(batch id: Int) {
        guard batchID == id, !completed else { return }
        completed = true
        watchdog?.invalidate()
        watchdog = nil
        wsTask?.cancel(with: .goingAway)
        wsTask = nil
        playerNode.stop()
        pendingBytes = Data()
        let cb = onError
        onAllPlayed = nil
        onError = nil
        cb?()
    }
}
