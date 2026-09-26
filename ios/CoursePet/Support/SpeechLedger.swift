// MARK: - 语音记账：端侧语音识别 + 口语句解析
// 两条链路：
// 1. SpeechLedgerController —— SpeechFramework 语音转文字（优先端侧识别，不上传云端，隐私友好）
// 2. LedgerNLParser —— 把"今天午饭花了十五块"这类口语解析成（金额, 分类, 备注）
import Foundation
import Speech
import AVFoundation

// MARK: - 口语句解析器（纯逻辑，无 UI 依赖）
enum LedgerNLParser {
    struct Result {
        let amount: Double
        let category: String
        let note: String?
    }

    /// 阿拉伯数字金额：如 "15块" "12.5元" "￥30"
    private static let arabicAmountRegex = try! NSRegularExpression(pattern: #"[¥￥]?\s*(\d+(?:\.\d+)?)\s*(?:块|元)"#)
    /// 中文数字金额：如 "十五块" "一百块" "两百五"
    private static let cnAmountRegex = try! NSRegularExpression(pattern: #"([零一二两三四五六七八九十百]{1,8})\s*(?:块|元)"#)

    /// 分类关键词映射（在备注原文里找第一个命中的分类）
    private static let categoryKeywords: [(category: String, keywords: [String])] = [
        ("餐饮", ["饭", "吃", "餐", "外卖", "奶茶", "咖啡", "面", "米线", "麻辣烫", "食堂", "零食", "面包", "小吃", "蜜雪", "瑞幸", "星巴克", "肯德基", "麦当劳", "烧烤", "火锅", "水饺", "包子"]),
        ("交通", ["打车", "地铁", "公交", "单车", "骑行", "滴滴", "高铁", "火车", "车票", "车费"]),
        ("日用", ["超市", "纸", "巾", "洗", "牙膏", "香皂", "日用品", "买菜", "水果", "水电", "洗衣"]),
        ("学习", ["书", "文具", "打印", "复印", "资料", "笔", "课程", "考试", "报名"]),
        ("娱乐", ["电影", "游戏", "会员", "B站", "腾讯视频", "爱奇艺", "网易云", "KTV", "唱", "演出", "充值"]),
    ]

    /// 主入口：句子 →（金额, 分类, 备注）；金额解析失败返回 nil
    static func parse(_ text: String) -> Result? {
        guard let amount = parseAmount(from: text) else { return nil }
        return Result(amount: amount, category: parseCategory(from: text), note: parseNote(from: text))
    }

    // MARK: 金额
    static func parseAmount(from text: String) -> Double? {
        // 优先阿拉伯数字
        let arabic = arabicAmountRegex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length))
        if let m = arabic, m.numberOfRanges >= 2 {
            if let v = Double((text as NSString).substring(with: m.range(at: 1))), v > 0 {
                return v
            }
        }
        // 再试中文数字
        let cn = cnAmountRegex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length))
        if let m = cn, m.numberOfRanges >= 2 {
            let segment = (text as NSString).substring(with: m.range(at: 1))
            if let v = cnNumberToDouble(segment), v > 0 {
                return v
            }
        }
        return nil
    }

    /// 中文数字串 → Double（覆盖 0~9999 口语表达）
    static func cnNumberToDouble(_ s: String) -> Double? {
        let digits: [String: Double] = ["零": 0, "一": 1, "两": 2, "二": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9]
        let units: [String: Double] = ["十": 10, "百": 100, "千": 1000]

        var result: Double = 0
        var current: Double = 0
        for ch in s {
            let c = String(ch)
            if let d = digits[c] {
                current = d
            } else if let u = units[c] {
                result += (current == 0 ? 1 : current) * u
                current = 0
            }
            // 其它字符（如"点/多/来"）忽略
        }
        result += current

        // 口语截尾特例："一百二"=120、"两百五"=250 —— 百位后单个数字结尾时该数字当十位
        let chars = Array(s)
        if chars.count >= 2, chars[chars.count - 2] == "百",
           let lastDigit = digits[String(chars[chars.count - 1])], lastDigit > 0 {
            result = result - lastDigit + lastDigit * 10
        }

        return result > 0 ? result : nil
    }

    // MARK: 分类
    static func parseCategory(from text: String) -> String {
        for (category, keywords) in categoryKeywords {
            if keywords.contains(where: text.contains) {
                return category
            }
        }
        return "其他"
    }

    // MARK: 备注
    static func parseNote(from text: String) -> String? {
        var note = text
        let noiseWords = ["我", "今天", "昨天", "上午", "下午", "中午", "早上", "晚上", "一共", "总共", "花了", "花", "用了", "用", "花费", "消费", "大概", "大约", "差不多", "左右", "块", "元钱", "钱", "一下", "记一笔", "帮我"]
        for word in noiseWords {
            note = note.replacingOccurrences(of: word, with: "")
        }
        note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !note.isEmpty else { return nil }
        return String(note.prefix(20))
    }
}

// MARK: - 语音识别控制器
/// 用法：@StateObject 持有，toggle() 开始/停止；
/// 录音期间实时更新 transcript，结束后（isRecording 变 false）对 transcript 跑 LedgerNLParser。
@MainActor
final class SpeechLedgerController: ObservableObject {
    @Published var transcript = ""
    @Published var isRecording = false
    @Published var errorMessage: String?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()

    func toggle() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    func startRecording() {
        errorMessage = nil
        transcript = ""
        // 语音识别权限 → 麦克风权限，逐级申请（回调切回主 actor 再操作 UI 状态）
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            Task { @MainActor in
                guard let self else { return }
                guard status == .authorized else {
                    self.errorMessage = "需要语音识别权限：设置 → 隐私与安全 → 语音识别"
                    return
                }
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    Task { @MainActor in
                        guard granted else {
                            self.errorMessage = "需要麦克风权限：设置 → 隐私与安全 → 麦克风"
                            return
                        }
                        self.beginSession()
                    }
                }
            }
        }
    }

    private func beginSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let request = SFSpeechAudioBufferRecognitionRequest()
            // 端侧识别：语音不出设备（新机型支持；旧机型自动回退在线识别）
            if recognizer?.supportsOnDeviceRecognition == true {
                request.requiresOnDeviceRecognition = true
            }
            request.shouldReportPartialResults = true
            recognitionRequest = request

            let input = audioEngine.inputNode
            let format = input.outputFormat(forBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                request.append(buffer)
            }
            audioEngine.prepare()
            try audioEngine.start()
            isRecording = true

            recognitionTask = recognizer?.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor in
                    if let result {
                        self?.transcript = result.bestTranscription.formattedString
                    }
                    if error != nil || result?.isFinal == true {
                        self?.stopRecording()
                    }
                }
            }
        } catch {
            errorMessage = "录音启动失败：\(error.localizedDescription)"
            isRecording = false
        }
    }

    func stopRecording() {
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
            recognitionRequest?.endAudio()
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        isRecording = false
    }

    /// 页面销毁时彻底清理
    func teardown() {
        stopRecording()
        recognitionTask?.cancel()
        recognitionTask = nil
    }
}
