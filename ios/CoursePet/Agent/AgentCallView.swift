// MARK: - 语音通话界面（对标 ChatGPT 语音通话：全屏 + 宠物 + 实时字幕 + 一个大挂断键）
// 视觉要点：深色沉浸背景 + 随状态变色的呼吸光晕 + 宠物形象居中最醒目 +
//          主人说的话/宠物说的话直接当字幕打在脸上（不用看气泡）。
import SwiftUI

struct AgentCallView: View {
    let engine: AgentEngine
    @EnvironmentObject private var dataManager: DataManager
    @Environment(\.dismiss) private var dismiss
    @StateObject private var call = AgentCallSession()
    // 通话朗读音量（独立于系统音量，见底部音量条说明）
    @ObservedObject private var speech = AgentSpeech.shared

    @State private var appeared = false

    var body: some View {
        ZStack {
            background
            VStack(spacing: 0) {
                header
                Spacer(minLength: 4)
                avatar
                Spacer(minLength: 4)
                subtitle
                if let reminder = call.softReminder { banner(reminder, color: .orange) }
                if let error = call.errorMessage { banner(error, color: .red) }
                callVolumeRow
                hangupButton
                Text("直接说话就行，随时打断我也不会生气")
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.35))
                    .padding(.top, 10)
            }
            .padding(.horizontal, 26)
            .padding(.top, 10)
            .padding(.bottom, 26)
        }
        .preferredColorScheme(.dark)
        .onAppear {
            appeared = true
            call.start(engine: engine)
        }
        .onDisappear { call.end() }
    }

    // MARK: 背景（深色渐变 + 随状态变色、呼吸的光晕）
    private var background: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.07, green: 0.07, blue: 0.12),
                                    Color(red: 0.14, green: 0.11, blue: 0.26),
                                    Color(red: 0.05, green: 0.05, blue: 0.09)],
                           startPoint: .top, endPoint: .bottom)
            Circle()
                .fill(RadialGradient(colors: [phaseColor.opacity(0.42), .clear],
                                     center: .center, startRadius: 8, endRadius: 330))
                .frame(width: 660, height: 660)
                .scaleEffect(appeared ? 1.06 : 0.92)
                .animation(.easeInOut(duration: 2.6).repeatForever(autoreverses: true), value: appeared)
                .allowsHitTesting(false)
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.5), value: call.phase)
    }

    // MARK: 顶栏（通话时长 / 轮数 / 当前状态）
    private var header: some View {
        HStack(spacing: 8) {
            Circle().fill(phaseColor).frame(width: 7, height: 7)
            Text(call.elapsedText)
                .font(.footnote.monospacedDigit())
                .foregroundColor(.white.opacity(0.7))
            if call.turns > 0 {
                Text("· 聊了 \(call.turns) 轮")
                    .font(.footnote)
                    .foregroundColor(.white.opacity(0.4))
            }
            Spacer()
            Text(phaseTitle)
                .font(.footnote)
                .foregroundColor(.white.opacity(0.55))
        }
    }

    // MARK: 宠物形象 + 呼吸光圈（用养成中心同款帧动画 PetAnimationView，
    // 不能用 LiveActivitySafePet——它自带踱步镜像翻转，在通话页看起来"像一张纸在转"）
    private var avatar: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .stroke(phaseColor.opacity(0.3), lineWidth: 1.5)
                    .frame(width: 214 + CGFloat(i) * 48, height: 214 + CGFloat(i) * 48)
                    .scaleEffect(appeared ? 1.05 : 0.93)
                    .opacity(appeared ? 0.18 : 0.55)
                    .animation(.easeInOut(duration: 2.2)
                        .repeatForever(autoreverses: true)
                        .delay(Double(i) * 0.25), value: appeared)
            }
            PetModelView(
                action: petAction,
                charId: dataManager.charId,
                speed: dataManager.animSpeed,
                size: 166,
                loop: true,
                threeDEffect: true
            )
            .id("call-pet-\(petAction)-\(dataManager.charId)")
        }
        .frame(maxWidth: .infinity)
        .frame(height: 300)
    }

    // MARK: 字幕（主人说的 / 宠物说的都打在这里）
    private var subtitle: some View {
        Text(subtitleText)
            .font(.title3)
            .fontWeight(subtitleEmphasized ? .medium : .regular)
            .foregroundColor(.white.opacity(subtitleEmphasized ? 0.95 : 0.5))
            .multilineTextAlignment(.center)
            .lineSpacing(3)
            .frame(maxWidth: .infinity, minHeight: 92, alignment: .top)
            .animation(.easeInOut(duration: 0.18), value: subtitleText)
    }

    // MARK: 提示条（软提示 / 错误）
    private func banner(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundColor(.white)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Capsule().fill(color.opacity(0.28)))
            .padding(.bottom, 10)
    }

    // MARK: 通话音量条（宠物说话声音的独立音量）
    // 为什么单独做一条：通话音频会话是 .playAndRecord（类似打电话的通道），
    // 系统 TTS 朗读在这个通道上不一定吃侧边音量键的"媒体音量"，
    // utterance.volume 是苹果给朗读器的独立增益，拖这个 100% 有效，能直接拖到静音。
    private var callVolumeRow: some View {
        HStack(spacing: 10) {
            Image(systemName: speech.callVolume <= 0.01 ? "speaker.slash.fill" : "speaker.wave.1.fill")
                .font(.system(size: 15))
                .foregroundColor(.white.opacity(0.55))
                .frame(width: 18)
            Slider(value: Binding(
                get: { Double(speech.callVolume) },
                set: { speech.setCallVolume(Float($0)) }
            ), in: 0...1)
            .tint(phaseColor)
            Image(systemName: "speaker.wave.3.fill")
                .font(.system(size: 15))
                .foregroundColor(.white.opacity(0.55))
                .frame(width: 18)
        }
        .padding(.horizontal, 22)
        .padding(.top, 14)
    }

    // MARK: 挂断
    private var hangupButton: some View {
        Button {
            call.end()
            dismiss()
        } label: {
            ZStack {
                Circle()
                    .fill(Color.red)
                    .frame(width: 68, height: 68)
                    .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
                Image(systemName: "phone.down.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundColor(.white)
            }
        }
        .buttonStyle(.plain)
        .padding(.top, 18)
    }

    // MARK: 状态 → 颜色 / 文案 / 宠物动作
    private var phaseColor: Color {
        switch call.phase {
        case .listening: return Color(red: 0.30, green: 0.83, blue: 0.70)   // 青绿：在听
        case .thinking:  return Color(red: 0.55, green: 0.52, blue: 0.98)   // 紫：在想
        case .speaking:  return Color(red: 0.96, green: 0.45, blue: 0.72)   // 粉：在说
        case .idle:      return Color.gray
        }
    }

    private var phaseTitle: String {
        switch call.phase {
        case .listening: return "听着呢"
        case .thinking:  return "想一下下"
        case .speaking:  return "在说"
        case .idle:      return "已挂断"
        }
    }

    private var petAction: String {
        switch call.phase {
        case .listening: return "listen"
        case .thinking:  return "idle"
        case .speaking:  return "happy"
        case .idle:      return "idle"
        }
    }

    private var subtitleText: String {
        switch call.phase {
        case .listening:
            if !call.liveTranscript.isEmpty { return call.liveTranscript }
            // 没在说话时，把上一句回答留着（暗色）当回看
            return call.answerText.isEmpty ? "你说，我听着～" : call.answerText
        case .thinking:
            return "让我想想…"
        case .speaking:
            return call.answerText.isEmpty ? "\(dataManager.petName)在说…" : call.answerText
        case .idle:
            return call.errorMessage == nil ? "通话结束啦" : ""
        }
    }

    /// 字幕是否"高亮"：主人正在说的话、宠物正在说的话 → 亮；等待提示 → 暗
    private var subtitleEmphasized: Bool {
        switch call.phase {
        case .listening: return !call.liveTranscript.isEmpty
        case .speaking:  return !call.answerText.isEmpty
        case .thinking, .idle: return false
        }
    }
}