// MARK: - 通用按钮/点击反馈（iOS 17+ 原生 API，零依赖）
// 用法：Button { ... } label: { Text("保存") }.tapFeedback()
// 效果：点下去缩放 0.95 + Haptic 轻触感 + 松开弹回动画
import SwiftUI
import UIKit

// MARK: - 核心 Modifier
struct PressScaleEffect: ViewModifier {
    @State private var pressed: Bool = false
    let onTap: () -> Void
    let style: FeedbackStyle

    func body(content: Content) -> some View {
        content
            .scaleEffect(pressed ? 0.95 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: pressed)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !pressed {
                            pressed = true
                            // Haptic：按 style 选不同强度
                            switch style {
                            case .light:    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            case .medium:   UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            case .success:  UINotificationFeedbackGenerator().notificationOccurred(.success)
                            case .confirm:   UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                            }
                        }
                    }
                    .onEnded { _ in
                        pressed = false
                        onTap()
                    }
            )
    }
}

/// 反馈风格：不同场景选不同触感
enum FeedbackStyle {
    case light      // 轻触：切换开关、勾选、chip 点击
    case medium     // 中等：保存、确认、添加（默认）
    case success    // 成功：完成任务、升级、保存成功
    case confirm    // 确认删除/清空等危险操作
}

extension View {
    /// 点按反馈：缩放 + Haptic + 执行 action
    func tapFeedback(_ style: FeedbackStyle = .medium, action: @escaping () -> Void) -> some View {
        modifier(PressScaleEffect(onTap: action, style: style))
    }

    /// 纯视觉反馈（只缩放，不触发 action——用于 Button 内部的 label）
    func pressScale() -> some View {
        modifier(PressScaleOnly())
    }
}

/// 只缩放不触发 action 的版本（给 Button label 用，避免重复触发）
struct PressScaleOnly: ViewModifier {
    @State private var pressed: Bool = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(pressed ? 0.96 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: pressed)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in pressed = true }
                    .onEnded   { _ in pressed = false }
            )
    }
}
