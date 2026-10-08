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
            .background(GlassSurface(cornerRadius: 14))
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

// MARK: - 写操作确认卡（宠物想替你写数据，先给你过目）
// 端侧写工具 / 服务器意图卡共用：pending 态出「记上 / 先不用」两个按钮，
// 点了之后引擎 resolveConfirmation 落库或放行；卡片状态只允许变一次（防连点重复写入）。
struct AgentConfirmationCardView: View {
    let conf: AgentConfirmation
    let messageID: UUID
    /// 用户点了「记上」（true）/「先不用」（false）；struct 不能持有 weak 引用，回调由调用方闭包捕获引擎
    var onResolve: (Bool) -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 10) {
                // 卡片头：图标 + 标题 + 待确认徽标
                HStack(spacing: 6) {
                    Image(systemName: conf.symbolName)
                        .font(.footnote.bold())
                        .foregroundColor(.indigo)
                    Text(conf.title)
                        .font(.subheadline.weight(.bold))
                        .foregroundColor(.primary)
                    Spacer(minLength: 0)
                    statusBadge
                }
                // 确认内容（工具已把要点逐行整理好）
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(conf.lines.indices, id: \.self) { i in
                        Text(conf.lines[i])
                            .font(.footnote)
                            .foregroundColor(.primary)
                    }
                }
                if conf.state == .pending {
                    // 操作区：确认是主动作（蓝底白字），放弃是弱动作（灰字）
                    HStack(spacing: 10) {
                        Button {
                            onResolve(true)
                        } label: {
                            Text("记上")
                                .font(.footnote.weight(.bold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 18)
                                .padding(.vertical, 7)
                                .background(Color.indigo, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        Button {
                            onResolve(false)
                        } label: {
                            Text("先不用")
                                .font(.footnote.weight(.semibold))
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                                .background(Color.secondary.opacity(0.14), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(12)
            .background(GlassSurface(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(conf.state == .confirmed
                            ? Color.green.opacity(0.4)
                            : Color.indigo.opacity(0.25), lineWidth: 1)
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 状态徽标：待确认（呼吸感的琥珀色）/ 已记好（绿）/ 没记（灰）
    @ViewBuilder
    private var statusBadge: some View {
        switch conf.state {
        case .pending:
            Text("待确认")
                .font(.caption2.weight(.bold))
                .foregroundColor(.orange)
        case .confirmed:
            Label("已记好", systemImage: "checkmark.circle.fill")
                .font(.caption2.weight(.bold))
                .foregroundColor(.green)
        case .declined:
            Text("没记")
                .font(.caption2.weight(.bold))
                .foregroundColor(.secondary)
        }
    }
}
