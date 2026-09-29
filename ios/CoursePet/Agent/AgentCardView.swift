// MARK: - 模式 11 结构化卡片渲染（Agent 输出 = UI）
// 聊天里的作业卡/课表卡/账单卡：数据来自 Agent 工具查询结果经 show_card 校验后的 schema，
// 点击整卡先关聊天页再走 coursepet:// 深链直达对应页面（onOpenURL 在主 App 层切 tab）。
import SwiftUI
import UIKit

struct AgentCardView: View {
    let card: AgentCard
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 10) {
                // 卡片头：类型图标 + 标题
                HStack(spacing: 6) {
                    Image(systemName: card.symbolName)
                        .font(.footnote.bold())
                        .foregroundColor(.indigo)
                    Text(card.title)
                        .font(.subheadline.weight(.bold))
                        .foregroundColor(.primary)
                    Spacer(minLength: 0)
                }
                // 条目列表（最多 12 条，由 AgentCard.parse 截断）
                ForEach(card.items.indices, id: \.self) { index in
                    let item = card.items[index]
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.primary)
                            .font(.footnote.weight(.semibold))
                            .foregroundColor(.primary)
                        if !item.secondary.isEmpty {
                            Text(item.secondary)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        if !item.tertiary.isEmpty {
                            Text(item.tertiary)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                // 底部：汇总行 + 直达提示
                HStack {
                    if !card.summary.isEmpty {
                        Text(card.summary)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    Spacer(minLength: 0)
                    Label(card.cardType == .jump ? "打开\(card.platformName)" : "查看全部",
                          systemImage: "arrow.up.right")
                        .font(.caption2.weight(.bold))
                        .foregroundColor(.indigo)
                }
            }
            .padding(12)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.indigo.opacity(0.25), lineWidth: 1)
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onTapGesture { open() }
    }

    private func open() {
        dismiss()
        // jump 卡两级跳：先试私有 scheme 直拉 App，失败回落 https 网页
        // （https 链接在装了对应 App 的真机上走 Universal Links，本身也会优先拉 App）
        if card.cardType == .jump, let scheme = card.schemeURL {
            UIApplication.shared.open(scheme) { ok in
                if !ok, let url = card.deepLink {
                    UIApplication.shared.open(url)
                }
            }
            return
        }
        if let url = card.deepLink {
            UIApplication.shared.open(url)
        }
    }
}
